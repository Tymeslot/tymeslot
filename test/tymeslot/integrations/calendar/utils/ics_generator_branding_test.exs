defmodule Tymeslot.Integrations.Calendar.IcsGeneratorBrandingTest do
  @moduledoc """
  The free-tier "Scheduled with Tymeslot" footer in an `.ics` description:
  present only when the instance shows branding, has a footer link, and the
  organiser's subscription calls for it.
  """

  # Swaps the global `:show_branding`, `:ics_branding_url` and
  # `:subscription_manager` settings.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations
  @moduletag :payments

  import Mox

  alias Tymeslot.Emails.Templates.CalendarInvitation
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings
  alias Tymeslot.Notifications.Email.CalendarEventDetails

  @url "https://tymeslot.example.com/?utm_source=ics"
  @footer "Scheduled with Tymeslot: #{@url}"

  setup :verify_on_exit!

  setup do
    previous_url = Application.get_env(:tymeslot, :ics_branding_url)
    previous_flag = Application.get_env(:tymeslot, :show_branding)
    previous_manager = Application.get_env(:tymeslot, :subscription_manager)
    Application.put_env(:tymeslot, :ics_branding_url, @url)
    Application.put_env(:tymeslot, :show_branding, true)
    # Pinned rather than inherited: other modules swap or delete it.
    Application.put_env(
      :tymeslot,
      :subscription_manager,
      Tymeslot.Payments.SubscriptionManagerMock
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :ics_branding_url, previous_url)
      Application.put_env(:tymeslot, :show_branding, previous_flag)
      Application.put_env(:tymeslot, :subscription_manager, previous_manager)
    end)

    # Only user 42 is on the free tier.
    stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, &(&1 == 42))
    :ok
  end

  defp ics(overrides) do
    %{
      title: "Intro call",
      description: "Agenda",
      start_time: ~U[2026-11-02 14:00:00Z],
      end_time: ~U[2026-11-02 14:30:00Z],
      uid: "branding-test",
      organizer_email: "host@example.com",
      organizer_name: "Host"
    }
    |> Map.merge(overrides)
    |> IcsGenerator.generate_ics()
    |> unfold()
  end

  defp unfold(ics), do: String.replace(ics, "\r\n ", "")

  test "a free-tier organiser's event ends its description with the footer" do
    assert ics(%{organizer_user_id: 42}) =~
             "Agenda\\n\\nScheduled with Tymeslot: #{@url}\r\nLOCATION"
  end

  test "a paying organiser's event carries no footer" do
    refute ics(%{organizer_user_id: 7}) =~ @footer
  end

  test "an event with no known organiser carries no footer" do
    refute ics(%{}) =~ @footer
  end

  test "an instance with branding switched off carries no footer" do
    Application.put_env(:tymeslot, :show_branding, false)

    refute ics(%{organizer_user_id: 42}) =~ @footer
  end

  test "an instance with no footer link never asks the subscription manager" do
    Application.put_env(:tymeslot, :ics_branding_url, nil)

    expect(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, 0, fn _id ->
      true
    end)

    refute ics(%{organizer_user_id: 42}) =~ "Scheduled with"
  end

  test "the footer follows the attendee's language" do
    ics =
      IcsGenerator.generate_ics(
        %{
          title: "Intro call",
          start_time: ~U[2026-11-02 14:00:00Z],
          end_time: ~U[2026-11-02 14:30:00Z],
          organizer_email: "host@example.com",
          organizer_name: "Host",
          organizer_user_id: 42
        },
        "de"
      )

    assert unfold(ics) =~ "Geplant mit Tymeslot: #{@url}"
  end

  test "a dashboard event's invitation email carries its organiser's footer" do
    {:ok, details} =
      CalendarEventDetails.invitation_details(
        %{id: 42, name: "Host", email: "host@example.com"},
        %{
          "event_title" => "Planning",
          "event_uid" => "invite-branding",
          "event_start_at" => "2026-11-02T14:00:00Z",
          "event_end_at" => "2026-11-02T15:00:00Z"
        }
      )

    email = CalendarInvitation.render("guest@example.com", details)

    [attachment] = Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))
    assert unfold(attachment.data) =~ @footer
  end

  describe "a stored booking" do
    setup do
      user = insert(:user)
      start_time = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          start_time: start_time,
          end_time: DateTime.add(start_time, 3600)
        )

      %{meeting: meeting, user: user}
    end

    test "the attendee's calendar download carries the organiser's footer", %{
      meeting: meeting,
      user: user
    } do
      stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, &(&1 == user.id))

      assert {:ok, ics} = Meetings.calendar_export(meeting.uid, user.id)
      assert unfold(ics) =~ @footer
    end

    test "a paying organiser's download carries none", %{meeting: meeting, user: user} do
      stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, fn _id -> false end)

      assert {:ok, ics} = Meetings.calendar_export(meeting.uid, user.id)
      refute unfold(ics) =~ @footer
    end
  end
end
