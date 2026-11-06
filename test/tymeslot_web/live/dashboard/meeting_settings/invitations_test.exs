defmodule TymeslotWeb.Dashboard.MeetingSettings.InvitationsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile =
      profile
      |> Changeset.change(username: "joern", timezone: "Europe/Berlin")
      |> Repo.update!()

    %{profile: profile}
  end

  defp open_editor(conn, type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()
    view
  end

  defp panel(type), do: "#invitations-#{type.id}"

  defp row(invitation), do: "#invitation-#{invitation.id}"

  defp invite!(user, type, attrs \\ %{}) do
    {:ok, invitation} = Invitations.create(user.id, type, attrs)
    invitation
  end

  defp book!(invitation, user, attrs) do
    insert(
      :meeting,
      Keyword.merge([organizer_user: user, invitation_id: invitation.id], attrs)
    )
  end

  test "switching a type to invitation-only replaces the direct link with the invitations panel",
       ctx do
    type = insert(:meeting_type, user: ctx.user, name: "Intro call")
    view = open_editor(ctx.conn, type)

    assert has_element?(view, "#copy-booking-link-#{type.id}")
    refute has_element?(view, panel(type))

    view |> element("#meeting-type-invitation-only-toggle-#{type.id}") |> render_click()

    assert Repo.reload!(type).invitation_only
    refute has_element?(view, "#copy-booking-link-#{type.id}")

    assert has_element?(
             view,
             panel(type),
             "No invitations yet. Create one link per person you want to invite."
           )
  end

  test "the card says invitation only in place of unlisted", ctx do
    insert(:meeting_type, user: ctx.user, invitation_only: true, is_private: true)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

    assert has_element?(view, "[data-testid='invitation-only']", "Invitation only")
    refute render(view) =~ "Unlisted"
  end

  test "the switch is disabled for a group type", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "Workshop", max_participants: 5)
    view = open_editor(ctx.conn, type)

    switch = "#meeting-type-invitation-only-toggle-#{type.id}"
    assert has_element?(view, "#{switch}[disabled]")
    assert render(view) =~ "Invitation links work only for one-to-one meeting types."

    # A forged click is refused by the domain, with its reason.
    view
    |> with_target("#meeting_settings")
    |> render_click("toggle_invitation_only", %{
      "id" => to_string(type.id),
      "invitation_only" => "true"
    })

    refute Repo.reload!(type).invitation_only

    assert has_element?(
             view,
             "#app-flash-group-error",
             "Invitation links work only for one-to-one meeting types."
           )
  end

  test "creating an invitation lists it as available with a copyable /invite/ link", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    view
    |> form("#{panel(type)}-form", invitation: %{name: "Ann Lee", email: "ann@example.com"})
    |> render_submit()

    [%{invitation: invitation, status: :available}] = Invitations.list(ctx.user.id, type)
    assert invitation.release_on_cancel
    assert has_element?(view, "#{row(invitation)}[data-status='available']", "Ann Lee")

    [_whole, token] =
      Regex.run(
        ~r{id="copy-invitation-#{invitation.id}"[^>]*data-copy-text="[^"]*/invite/([^"]+)"},
        render(view)
      ) ||
        Regex.run(
          ~r{data-copy-text="[^"]*/invite/([^"]+)"[^>]*id="copy-invitation-#{invitation.id}"},
          render(view)
        )

    assert {:ok, resolved} = Invitations.resolve(token)
    assert resolved.id == invitation.id

    # The form is cleared for the next person.
    assert has_element?(view, "#{panel(type)}-form input[name='invitation[name]'][value='']")
  end

  test "a booked invitation shows as used with the booked time and the differing email", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    invitation = invite!(ctx.user, type, %{name: "Ann Lee", email: "ann@example.com"})

    book!(invitation, ctx.user,
      status: :confirmed,
      attendee_email: "ann.work@example.com",
      start_time: ~U[2030-06-14 08:00:00Z],
      end_time: ~U[2030-06-14 09:00:00Z]
    )

    view = open_editor(ctx.conn, type)

    assert has_element?(view, "#{row(invitation)}[data-status='used']")
    # 08:00 UTC is 10:00 in the host's Berlin summer time.
    assert has_element?(view, "#{row(invitation)} [data-testid='invitation-booked-at']", "10:00")

    assert has_element?(
             view,
             "#{row(invitation)} [data-testid='invitation-booked-as']",
             "Booked as ann.work@example.com"
           )

    refute has_element?(view, "#copy-invitation-#{invitation.id}")
  end

  test "revoking shows revoked, and the booking stays", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    open = invite!(ctx.user, type, %{name: "Open link"})
    used = invite!(ctx.user, type, %{name: "Used link"})
    meeting = book!(used, ctx.user, status: :confirmed)
    view = open_editor(ctx.conn, type)

    view |> element("#{row(open)} [phx-click='ask_revoke']") |> render_click()
    assert render(view) =~ "It will stop working. Any appointment already booked stays booked."
    view |> element("#{panel(type)}-revoke-modal button", "Revoke link") |> render_click()

    assert has_element?(view, "#{row(open)}[data-status='revoked']")
    refute has_element?(view, "#copy-invitation-#{open.id}")

    # Revoking a used link leaves its appointment booked.
    view |> with_target(panel(type)) |> render_click("revoke", %{"id" => used.id})

    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert has_element?(view, "#{row(used)}[data-status='used']")
  end

  test "reopen appears only when allowed and makes the link available", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    held = invite!(ctx.user, type, %{name: "Held"})
    book!(held, ctx.user, status: :confirmed)
    spent = invite!(ctx.user, type, %{name: "Spent", release_on_cancel: false})
    # Booked before the reopen below, so the reopen frees the link from it.
    book!(spent, ctx.user,
      status: :cancelled,
      inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
    )

    view = open_editor(ctx.conn, type)

    assert has_element?(view, "#{row(held)}[data-status='used']")
    refute has_element?(view, "#{row(held)} [phx-click='reopen']")
    assert has_element?(view, "#{row(spent)}[data-status='used']")

    view |> element("#{row(spent)} [phx-click='reopen']") |> render_click()

    assert has_element?(view, "#{row(spent)}[data-status='available']")
    assert has_element?(view, "#copy-invitation-#{spent.id}")

    # A revoked link can be reopened too.
    {:ok, _revoked} = Invitations.revoke(ctx.user.id, spent.id)
    view = open_editor(ctx.conn, type)
    view |> element("#{row(spent)} [phx-click='reopen']") |> render_click()
    assert has_element?(view, "#{row(spent)}[data-status='available']")
  end

  test "hitting the rate limit shows the message", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    :ok =
      RateLimiter.consume(
        :invitation_create,
        ctx.user.id,
        RateLimiter.remaining(:invitation_create, ctx.user.id)
      )

    view
    |> form("#{panel(type)}-form", invitation: %{name: "Ann Lee"})
    |> render_submit()

    assert has_element?(view, "[data-testid='invitation-form-error']")
    assert Invitations.list(ctx.user.id, type) == []
    # What was typed is kept for a later try.
    assert has_element?(
             view,
             "#{panel(type)}-form input[name='invitation[name]'][value='Ann Lee']"
           )
  end

  test "another host's invitation id is refused", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    other = insert(:user)
    other_type = insert(:meeting_type, user: other, invitation_only: true)
    foreign = invite!(other, other_type)
    view = open_editor(ctx.conn, type)

    view |> with_target(panel(type)) |> render_click("revoke", %{"id" => foreign.id})
    view |> with_target(panel(type)) |> render_click("reopen", %{"id" => foreign.id})

    assert [%{status: :available}] = Invitations.list(other.id, other_type)
    assert has_element?(view, panel(type))
  end

  test "group bookings cannot be switched on for an invitation-only type", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    group_switch = "input[id^='group-bookings-toggle-']"
    assert has_element?(view, "#{group_switch}[disabled]")
    assert render(view) =~ "Invitation links work only for one-to-one meeting types."

    view
    |> with_target("[id^='meeting-type-form-wrapper-']")
    |> render_click("toggle_group_bookings", %{})

    assert Repo.reload!(type).max_participants in [nil, 1]
  end

  test "the expiry is the end of the chosen day in the host's timezone", ctx do
    ctx.profile |> Changeset.change(timezone: "Pacific/Auckland") |> Repo.update!()
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    view
    |> form("#{panel(type)}-form", invitation: %{expires_on: "2030-06-15"})
    |> render_submit()

    [%{invitation: invitation}] = Invitations.list(ctx.user.id, type)
    # 23:59:59 on 15 June in Auckland (NZST, UTC+12).
    assert invitation.expires_at == ~U[2030-06-15 11:59:59Z]
    assert has_element?(view, "#{row(invitation)} [data-testid='invitation-expiry']")
  end
end
