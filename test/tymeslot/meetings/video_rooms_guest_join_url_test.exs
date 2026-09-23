defmodule Tymeslot.Meetings.VideoRoomsGuestJoinUrlTest do
  @moduledoc """
  The link a booking's guests are given.

  A guest is a third party the booker invited: they own neither
  `organizer_video_url` nor `attendee_video_url`, and there is no column their
  own link could live in, since a booking may have any number of them. They
  were therefore handed the bare `meeting_url`, which is a location and
  nothing more.

  That stopped being enough with Jitsi. On a server configured for JWT
  authentication only a link carrying a signed token opens the room, so a
  guest holding the bare URL could accept the invitation and then not get in,
  and on a server that does not enforce tokens the room stayed reachable by
  URL alone, which is the very thing the tokens exist to prevent.

  `VideoRooms.guest_join_url/1` builds that link at send time. It names
  nobody, so no guest enters as the booker, and it never confers moderator
  rights. Every other provider's link is unchanged: they hand back the room
  URL they always did.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integrations
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Joken.Signer
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorkerHandlers

  @app_id "tymeslot"
  @secret "jitsi-shared-secret-of-at-least-32-bytes"
  @grace_seconds 4 * 60 * 60
  @jitsi_server "https://meet.example.com"
  @room_id "0123456789abcdef"
  @room_url @jitsi_server <> "/" <> @room_id

  # Links only a personal mint would produce, so a test can tell the guests'
  # link apart from the two the meeting already stores.
  @organizer_url "https://stored.example.com/organiser-link"
  @attendee_url "https://stored.example.com/attendee-link"

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    insert(:profile, user: user)

    %{user: user}
  end

  describe "guest_join_url/1 on a Jitsi integration with token credentials" do
    setup %{user: user} do
      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      %{meeting: insert_meeting(user, integration, "jitsi")}
    end

    test "hands the guests a token that names nobody and is not a moderator", %{
      meeting: meeting
    } do
      url = VideoRooms.guest_join_url(meeting)

      assert String.starts_with?(url, @room_url <> "?jwt=")

      # No `name`, no `email`: the reason guests were kept off the booker's
      # link in the first place was that it would put them in the room under
      # the booker's identity, and this one asserts no identity at all.
      assert verified_claims(url)["context"]["user"] == %{"moderator" => false}
    end

    test "scopes the token to this booking's room and to its start time", %{meeting: meeting} do
      claims = meeting |> VideoRooms.guest_join_url() |> verified_claims()

      assert claims["room"] == @room_id
      assert claims["exp"] == DateTime.to_unix(meeting.start_time) + @grace_seconds
    end

    test "hands out the room URL once the integration is switched off", %{
      meeting: meeting,
      user: user
    } do
      assert {:ok, %{is_active: false}} =
               Video.toggle_integration(user.id, meeting.video_integration_id)

      assert VideoRooms.guest_join_url(meeting) == @room_url
    end

    test "hands out the room URL once the integration is gone", %{meeting: meeting, user: user} do
      assert {:ok, :deleted} = Video.delete_integration(user.id, meeting.video_integration_id)

      assert VideoRooms.guest_join_url(meeting) == @room_url
    end
  end

  describe "guest_join_url/1 on an integration that signs nothing" do
    test "hands out the bare room URL on a Jitsi server with no credentials", %{user: user} do
      integration = create_jitsi(user, [])
      meeting = insert_meeting(user, integration, "jitsi")

      assert VideoRooms.guest_join_url(meeting) == @room_url
    end

    test "hands out the bare room URL on a provider whose links carry no token", %{user: user} do
      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          base_url: "https://video.example.com"
        )

      meeting = insert_meeting(user, integration, "mirotalk")

      assert VideoRooms.guest_join_url(meeting) == @room_url
    end

    test "hands out the room URL for a booking whose room was never attached", %{user: user} do
      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)

      meeting =
        insert_meeting(user, integration, "jitsi", %{
          video_room_id: nil,
          video_room_enabled: false
        })

      assert VideoRooms.guest_join_url(meeting) == @room_url
    end

    test "answers nothing for a booking with no video at all", %{user: user} do
      meeting =
        insert(:meeting,
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      assert VideoRooms.guest_join_url(meeting) == nil
    end
  end

  describe "the guests' confirmation email" do
    setup do
      TestMocks.setup_email_mocks()

      original_service = Application.get_env(:tymeslot, :email_service_module)
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

      # Delivery runs inside the circuit-breaker process, so the Swoosh test
      # adapter is pointed back at this test to collect what was sent. Safe
      # because the module is `async: false`.
      Application.put_env(:swoosh, :shared_test_process, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :email_service_module, original_service)
        Application.delete_env(:swoosh, :shared_test_process)
      end)

      :ok
    end

    test "carries the tokenised link, and neither the host's nor the booker's", %{user: user} do
      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      meeting = insert_meeting(user, integration, "jitsi")
      {:ok, [_guest]} = Guests.create_for_meeting(meeting.id, ["greg@example.com"])

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      guest_email = delivered_email_to("greg@example.com")

      for body <- [guest_email.html_body, guest_email.text_body] do
        assert body =~ "jwt="
        refute body =~ @organizer_url
        refute body =~ @attendee_url
      end

      # Read out of the plain-text body, where the URL is written verbatim.
      claims = guest_email.text_body |> token_from_body() |> verified_claims()

      assert claims["context"]["user"] == %{"moderator" => false}
      assert claims["room"] == @room_id
    end
  end

  describe "the appointment details payload" do
    test "carries one guests' link for the whole booking", %{user: user} do
      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      meeting = insert_meeting(user, integration, "jitsi")

      details = AppointmentBuilder.from_meeting(meeting)

      assert verified_claims(details.guest_video_url)["room"] == @room_id

      # Built alongside the two stored links rather than in place of them.
      assert details.organizer_video_url == @organizer_url
      assert details.attendee_video_url == @attendee_url
    end
  end

  # ----- helpers -----

  defp create_jitsi(user, credentials) do
    attrs = Map.merge(%{name: "Our Jitsi", base_url: @jitsi_server}, Map.new(credentials))

    {:ok, integration} = Video.create_integration(user.id, :jitsi, attrs)
    integration
  end

  defp insert_meeting(user, integration, provider, overrides \\ %{}) do
    start_time = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    insert(
      :meeting,
      Map.merge(
        %{
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: start_time,
          end_time: DateTime.add(start_time, 60, :minute),
          duration: 60,
          status: "confirmed",
          organizer_email_sent: false,
          attendee_email_sent: false,
          video_integration_id: integration.id,
          video_provider: provider,
          video_room_id: @room_id,
          video_room_enabled: true,
          meeting_url: @room_url,
          organizer_video_url: @organizer_url,
          attendee_video_url: @attendee_url
        },
        overrides
      )
    )
  end

  # The organiser, the booker and the one guest, so the find below cannot
  # silently pass over a batch that never arrived.
  defp delivered_email_to(address) do
    emails =
      Enum.map(1..3, fn _one_of_three ->
        assert_receive {:email, email}, 1_000
        email
      end)

    email = Enum.find(emails, fn email -> email.to |> hd() |> elem(1) == address end)
    assert email, "expected an email addressed to #{address}, got #{inspect(emails)}"
    email
  end

  defp token_from_body(body) do
    assert [_match, token] = Regex.run(~r/jwt=([A-Za-z0-9_\-\.]+)/, body)
    token
  end

  # Verifying against the configured secret, rather than only decoding the
  # payload, also proves the token is signed with it.
  defp verified_claims(token_or_url) do
    token =
      case URI.parse(token_or_url) do
        %URI{query: query} when is_binary(query) -> Map.fetch!(URI.decode_query(query), "jwt")
        _bare_token -> token_or_url
      end

    assert {:ok, claims} = Joken.verify(token, Signer.create("HS256", @secret))
    claims
  end
end
