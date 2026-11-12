defmodule TymeslotWeb.Live.Scheduling.EmbeddedRefusalRedirectTest do
  @moduledoc """
  A guest refused inside an embedded booking page (an unknown slug, a type
  with no times open, an invitation-only type without a valid link) is sent to
  the organiser's profile page. That redirect has to stay an embed, in the
  embed's theme, layout and colour, or the guest lands on the full profile
  page inside the host's iframe. Only values the page verified are carried:
  a crafted `?embed=1&parent-origin=` on a page that is not embedded mints
  nothing.

  Inside an embed the session is ignored, so the refusal's flash never
  reaches the page it redirects to; the redirect carries the reason as a
  closed `refused=` code instead, which the page turns back into the same
  message. The `describe "the refusal's message"` block follows the redirect
  the way an iframe does, a static GET with the cookie jar, since `live/2`
  hands the flash over in its redirect tuple and so cannot see it lost.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :embed
  @moduletag :live

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Phoenix.HTML
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Invitations
  alias Tymeslot.Repo
  alias TymeslotWeb.Live.Scheduling.InvitationMessages

  @username "refusedembedhost"
  @timezone "Etc/UTC"
  @embed_query "embed=1&theme=2&layout=column&primary-color=%23ff0000&timezone=#{@timezone}"

  setup do
    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", @username, @timezone)

    profile =
      profile
      |> Changeset.change(allowed_embed_domains: ["embedder.test"])
      |> Repo.update!()

    %{user: user, profile: profile}
  end

  defp embedded(conn), do: put_req_header(conn, "referer", "https://embedder.test/page")

  defp assert_stays_embedded(to) do
    assert %URI{path: "/" <> @username} = URI.parse(to)
    assert_carries_embed(to)
  end

  defp assert_carries_embed(to) do
    params = to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params["embed"] == "1"
    assert params["parent-origin"] == "https://embedder.test"
    assert params["theme"] == "2"
    assert params["layout"] == "column"
    assert params["primary-color"] == "#ff0000"
  end

  @tag :capture_log
  test "an unknown slug keeps the embed", %{conn: conn} do
    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> embedded() |> live("/#{@username}/no-such-type?#{@embed_query}")

    assert flash["error"] =~ "Invalid meeting type"
    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "a type with no times open keeps the embed", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Fixed",
      slug: "fixed",
      duration_minutes: 30,
      is_active: true,
      fixed_dates: true,
      max_participants: 1
    )

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> embedded() |> live("/#{@username}/fixed?#{@embed_query}")

    assert flash["info"] == "This meeting type has no times open for booking right now."
    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "an invitation-only type without a link keeps the embed", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Coaching",
      slug: "coaching",
      duration_minutes: 30,
      is_active: true,
      invitation_only: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/coaching?#{@embed_query}")

    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "a wrong invitation link keeps the embed too", %{conn: conn, user: user} do
    type =
      insert(:meeting_type,
        user: user,
        name: "Coaching",
        slug: "coaching",
        duration_minutes: 30,
        is_active: true,
        invitation_only: true
      )

    {:ok, _invitation} = Invitations.create(user.id, type, %{name: "Ada", email: "a@example.com"})

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/coaching?invite=wrong&#{@embed_query}")

    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "embed parameters on a page that is not embedded are not carried", %{conn: conn} do
    # Without `embed=1` the embed token plug signs nothing, so the page is not
    # embedded and none of the raw params may reach the redirect.
    assert {:error, {:redirect, %{to: to}}} =
             live(
               conn,
               "/#{@username}/no-such-type?parent-origin=https%3A%2F%2Fevil.test&theme=2&layout=column&primary-color=%23ff0000&timezone=#{@timezone}"
             )

    assert to == "/" <> @username
  end

  @tag :capture_log
  test "a booking step entered without a chosen time sends the guest back to the schedule inside the embed",
       %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Quick chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/quick-chat/book?#{@embed_query}")

    assert %URI{path: path} = URI.parse(to)
    assert path == "/#{@username}/quick-chat"
    assert_carries_embed(to)
  end

  @tag :capture_log
  test "the same step, not embedded, carries no embed parameters", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Quick chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             live(
               conn,
               "/#{@username}/quick-chat/book?parent-origin=https%3A%2F%2Fevil.test&layout=column&timezone=#{@timezone}"
             )

    assert to == "/#{@username}/quick-chat"
  end

  describe "the refusal's message" do
    # The real iframe load: a static GET refused with a redirect, then the GET
    # of where it points, with only what the cookie jar kept (`recycle/1`).
    defp follow_embedded_refusal(conn, path) do
      conn = conn |> embedded() |> get(path)
      to = redirected_to(conn, 302)

      body = conn |> recycle() |> embedded() |> get(to) |> html_response(200)

      {to, body}
    end

    defp refused_code(to),
      do: to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("refused")

    defp insert_invitation_only(user) do
      insert(:meeting_type,
        user: user,
        name: "Coaching",
        slug: "coaching",
        duration_minutes: 30,
        is_active: true,
        invitation_only: true
      )
    end

    @tag :capture_log
    test "an unknown slug says the type is invalid", %{conn: conn} do
      {to, body} = follow_embedded_refusal(conn, "/#{@username}/no-such-type?#{@embed_query}")

      assert refused_code(to) == "invalid-type"
      assert body =~ "Invalid meeting type"
    end

    @tag :capture_log
    test "a type with no times open says so", %{conn: conn, user: user} do
      insert(:meeting_type,
        user: user,
        name: "Fixed",
        slug: "fixed",
        duration_minutes: 30,
        is_active: true,
        fixed_dates: true,
        max_participants: 1
      )

      {to, body} = follow_embedded_refusal(conn, "/#{@username}/fixed?#{@embed_query}")

      assert refused_code(to) == "no-times-open"
      assert body =~ "This meeting type has no times open for booking right now."
    end

    @tag :capture_log
    test "an invitation-only type without a link says one is needed", %{conn: conn, user: user} do
      insert_invitation_only(user)

      {to, body} = follow_embedded_refusal(conn, "/#{@username}/coaching?#{@embed_query}")

      assert refused_code(to) == "invitation-required"
      assert body =~ html_escape(InvitationMessages.message(:required))
    end

    for reason <- [:used, :expired, :revoked] do
      @tag :capture_log
      test "an invitation link that is #{reason} says why", %{conn: conn, user: user} do
        type = insert_invitation_only(user)

        {:ok, invitation} =
          Invitations.create(user.id, type, %{name: "Ada", email: "a@example.com"})

        spend(invitation, user, unquote(reason))

        {to, body} =
          follow_embedded_refusal(
            conn,
            "/#{@username}/coaching?invite=#{invitation.token}&#{@embed_query}"
          )

        assert refused_code(to) == "invitation-#{unquote(reason)}"
        assert body =~ html_escape(InvitationMessages.message(unquote(reason)))
      end
    end

    @tag :capture_log
    test "the message is still there once the embed connects", %{conn: conn} do
      conn = conn |> embedded() |> get("/#{@username}/no-such-type?#{@embed_query}")
      to = redirected_to(conn, 302)

      {:ok, _view, html} = conn |> recycle() |> embedded() |> live(to)

      assert html =~ "Invalid meeting type"
    end

    test "an unknown code says nothing", %{conn: conn} do
      body =
        conn
        |> embedded()
        |> get("/#{@username}?refused=%3Cb%3Ehacked%3C%2Fb%3E&#{@embed_query}")
        |> html_response(200)

      refute body =~ "hacked"
      refute body =~ "Invalid meeting type"
    end

    test "a page that is not embedded ignores the code", %{conn: conn} do
      body = conn |> get("/#{@username}?refused=invalid-type") |> html_response(200)

      refute body =~ "Invalid meeting type"
    end
  end

  defp spend(invitation, user, :used),
    do: insert(:meeting, organizer_user: user, status: :confirmed, invitation_id: invitation.id)

  defp spend(invitation, _user, :expired) do
    invitation
    |> Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second))
    |> Repo.update!()
  end

  defp spend(invitation, user, :revoked),
    do: {:ok, _revoked} = Invitations.revoke(user.id, invitation.id)

  defp html_escape(text), do: text |> HTML.html_escape() |> HTML.safe_to_string()
end
