defmodule TymeslotWeb.Dashboard.MeetingSettings.InvitationsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
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

  # The link the copy button of an invitation carries.
  defp copied_url(view, invitation) do
    view
    |> element("#copy-invitation-#{invitation.id}")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("data-copy-text")
    |> hd()
  end

  # Invitations written straight to the table, in bulk.
  defp insert_invitations(user, type, count) do
    now = DateTime.utc_now(:second)

    rows =
      for n <- 1..count do
        %{
          user_id: user.id,
          meeting_type_id: type.id,
          token: "token-#{n}-#{System.unique_integer([:positive])}",
          token_hash: "hash-#{n}-#{System.unique_integer([:positive])}",
          release_on_cancel: true,
          inserted_at: DateTime.add(now, -n, :second),
          updated_at: now
        }
      end

    Repo.insert_all(InvitationSchema, rows)
  end

  # A revoked invitation whose expiry has since passed. The context refuses a
  # past expiry, so the date is moved back in the table.
  defp revoked_and_lapsed!(user, type, name) do
    invitation = invite!(user, type, %{name: name})
    {:ok, revoked} = Invitations.revoke(user.id, invitation.id)

    revoked
    |> Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -3600, :second))
    |> Repo.update!()
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
    type = insert(:meeting_type, user: ctx.user, invitation_only: true, is_private: true)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

    assert has_element?(view, "[data-testid='invitation-only']", "Invitation only")

    # Why it is invitation only reaches keyboards and screen readers too.
    tip = "meeting-type-#{type.id}-invitation-only-tip"

    assert has_element?(
             view,
             "[data-testid='invitation-only'][tabindex='0'][aria-describedby='#{tip}']"
           )

    assert has_element?(
             view,
             "##{tip}[role='tooltip']",
             "booked only through the invitation links"
           )

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

    assert [_whole, token] = Regex.run(~r{/invite/(.+)$}, copied_url(view, invitation))

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

    # Reopen is offered on the cancelled one, and the row says why.
    assert has_element?(view, "#{row(spent)} [data-testid='invitation-cancelled']")
    refute has_element?(view, "#{row(held)} [data-testid='invitation-cancelled']")

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

    assert has_element?(
             view,
             "[data-testid='invitation-form-error']",
             "You've reached the limit of"
           )

    assert Invitations.list(ctx.user.id, type) == []
    # What was typed is kept for a later try.
    assert has_element?(
             view,
             "#{panel(type)}-form input[name='invitation[name]'][value='Ann Lee']"
           )
  end

  test "revoking another host's invitation is refused and changes nothing", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    other = insert(:user)
    other_type = insert(:meeting_type, user: other, invitation_only: true)
    foreign = invite!(other, other_type)
    view = open_editor(ctx.conn, type)

    view |> with_target(panel(type)) |> render_click("revoke", %{"id" => foreign.id})

    assert Repo.reload!(foreign).revoked_at == nil
    assert [%{status: :available}] = Invitations.list(other.id, other_type)
    assert has_element?(view, "#app-flash-group-error", "That invitation can't be changed.")
  end

  test "reopening another host's revoked invitation is refused and it stays revoked", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    other = insert(:user)
    other_type = insert(:meeting_type, user: other, invitation_only: true)
    foreign = invite!(other, other_type)
    {:ok, _revoked} = Invitations.revoke(other.id, foreign.id)
    view = open_editor(ctx.conn, type)

    view |> with_target(panel(type)) |> render_click("reopen", %{"id" => foreign.id})

    assert Repo.reload!(foreign).revoked_at
    assert [%{status: :revoked}] = Invitations.list(other.id, other_type)
    assert has_element?(view, "#app-flash-group-error", "That invitation can't be changed.")
  end

  test "a revoked link whose expiry has passed offers no reopen", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    lapsed = revoked_and_lapsed!(ctx.user, type, "Lapsed")
    current = invite!(ctx.user, type, %{name: "Current"})
    {:ok, _revoked} = Invitations.revoke(ctx.user.id, current.id)
    view = open_editor(ctx.conn, type)

    assert has_element?(view, "#{row(lapsed)}[data-status='revoked']")
    refute has_element?(view, "#{row(lapsed)} [phx-click='reopen']")
    # A revoked link that has not expired can still be reopened.
    assert has_element?(view, "#{row(current)} [phx-click='reopen']")
  end

  test "a forged reopen of a revoked, expired link says it has expired", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    lapsed = revoked_and_lapsed!(ctx.user, type, "Lapsed")
    view = open_editor(ctx.conn, type)

    view |> with_target(panel(type)) |> render_click("reopen", %{"id" => lapsed.id})

    assert Repo.reload!(lapsed).revoked_at
    assert has_element?(view, "#{row(lapsed)}[data-status='revoked']")

    assert has_element?(
             view,
             "#app-flash-group-error",
             "This link has expired, so it can't be reopened. Create a new one instead."
           )
  end

  test "switching invitation-only off brings the direct booking link back", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    assert has_element?(view, panel(type))
    refute has_element?(view, "#copy-booking-link-#{type.id}")

    view |> element("#meeting-type-invitation-only-toggle-#{type.id}") |> render_click()

    refute Repo.reload!(type).invitation_only
    refute has_element?(view, panel(type))
    assert has_element?(view, "#copy-booking-link-#{type.id}")
  end

  test "creating a link after the type stopped being invitation-only is refused", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    {:ok, _listed} = MeetingTypes.set_invitation_only(type, false)

    view
    |> form("#{panel(type)}-form", invitation: %{name: "Ann Lee"})
    |> render_submit()

    assert Invitations.list(ctx.user.id, type) == []

    assert has_element?(
             view,
             "#app-flash-group-error",
             "Invitation links are off for this type."
           )
  end

  test "the copy button carries the link and its copied feedback", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    invitation = invite!(ctx.user, type, %{name: "Ann Lee"})
    view = open_editor(ctx.conn, type)

    assert has_element?(
             view,
             "#copy-invitation-#{invitation.id}[phx-hook='CopyOnClick']" <>
               "[data-copy-feedback='Invitation link copied!']"
           )

    assert {:ok, %{id: id}} =
             view
             |> copied_url(invitation)
             |> String.split("/invite/")
             |> List.last()
             |> Invitations.resolve()

    assert id == invitation.id
  end

  test "group bookings cannot be switched on for an invitation-only type", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    group_switch = "input[id^='group-bookings-toggle-']"
    participants = "input[name='meeting_type[max_participants_input]']"
    assert has_element?(view, "#{group_switch}[disabled]")
    assert render(view) =~ "Invitation links work only for one-to-one meeting types."

    # A forged click only changes the form's state, so the form is what shows
    # whether the blocker held: the switch stays off and no limit input opens.
    view
    |> with_target("[id^='meeting-type-form-wrapper-']")
    |> render_click("toggle_group_bookings", %{})

    refute has_element?(view, "#{group_switch}[checked]")
    refute has_element?(view, participants)
    assert render(view) =~ "Invitation links work only for one-to-one meeting types."
  end

  test "the expiry is the end of the chosen day in the host's timezone", ctx do
    ctx.profile |> Changeset.change(timezone: "Pacific/Auckland") |> Repo.update!()
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    view
    |> form("#{panel(type)}-form", %{})
    |> render_submit(invitation: %{expires_on: "2030-06-15"})

    [%{invitation: invitation}] = Invitations.list(ctx.user.id, type)
    # 23:59:59 on 15 June in Auckland (NZST, UTC+12).
    assert invitation.expires_at == ~U[2030-06-15 11:59:59Z]
    assert has_element?(view, "#{row(invitation)} [data-testid='invitation-expiry']")
  end

  test "the expiry on a daylight-saving change day is the end of that local day", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    # Berlin springs forward on 2030-03-31, so the day ends at UTC+2, not +1.
    view
    |> form("#{panel(type)}-form", %{})
    |> render_submit(invitation: %{expires_on: "2030-03-31"})

    [%{invitation: invitation}] = Invitations.list(ctx.user.id, type)
    assert invitation.expires_at == ~U[2030-03-31 21:59:59Z]
  end

  test "a past expiry date shows the error on the date field", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    view
    |> form("#{panel(type)}-form", %{})
    |> render_submit(invitation: %{expires_on: "2020-01-01"})

    assert Invitations.list(ctx.user.id, type) == []
    assert has_element?(view, "#{panel(type)}-form", "must be in the future")
    refute has_element?(view, "[data-testid='invitation-form-error']")
  end

  test "the reuse switch decides whether a cancelled booking frees the link", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    view = open_editor(ctx.conn, type)

    view |> element("#{panel(type)}-release-on-cancel") |> render_click()

    view
    |> form("#{panel(type)}-form", invitation: %{name: "One-off"})
    |> render_submit()

    [%{invitation: invitation}] = Invitations.list(ctx.user.id, type)
    refute invitation.release_on_cancel

    # The switch is back on for the next link.
    view
    |> form("#{panel(type)}-form", invitation: %{name: "Reusable"})
    |> render_submit()

    assert [%{invitation: %{release_on_cancel: false}}, %{invitation: %{release_on_cancel: true}}] =
             Enum.reverse(Invitations.list(ctx.user.id, type))
  end

  test "the buttons are named after the invitee, falling back to the email and then nothing",
       ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    named = invite!(ctx.user, type, %{name: "Ann Lee", email: "ann@example.com"})
    by_email = invite!(ctx.user, type, %{email: "bob@example.com"})
    unnamed = invite!(ctx.user, type)
    view = open_editor(ctx.conn, type)

    assert has_element?(view, "#copy-invitation-#{named.id}[aria-label='Copy link for Ann Lee']")
    assert has_element?(view, "#{row(named)} [aria-label='Revoke link for Ann Lee']")

    assert has_element?(
             view,
             "#copy-invitation-#{by_email.id}[aria-label='Copy link for bob@example.com']"
           )

    assert has_element?(view, "#copy-invitation-#{unnamed.id}[aria-label='Copy link']")
    assert has_element?(view, "#{row(unnamed)} [aria-label='Revoke link']")

    {:ok, _revoked} = Invitations.revoke(ctx.user.id, named.id)
    view = open_editor(ctx.conn, type)
    assert has_element?(view, "#{row(named)} [aria-label='Reopen link for Ann Lee']")
  end

  test "an available link whose token cannot be read says so instead of offering a copy", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    now = DateTime.utc_now(:second)

    Repo.insert_all("meeting_type_invitations", [
      %{
        user_id: ctx.user.id,
        meeting_type_id: type.id,
        token_encrypted: "not a ciphertext",
        token_hash: "unreadable-#{System.unique_integer([:positive])}",
        release_on_cancel: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    view = open_editor(ctx.conn, type)

    assert has_element?(
             view,
             "[data-testid='invitation-token-unavailable']",
             "This link can't be shown. Revoke it and create a new one."
           )

    refute has_element?(view, "[id^='copy-invitation-']")
    assert has_element?(view, "[phx-click='ask_revoke']")
  end

  test "only the newest hundred are listed, with a note when there are more", ctx do
    type = insert(:meeting_type, user: ctx.user, invitation_only: true)
    insert_invitations(ctx.user, type, 100)
    view = open_editor(ctx.conn, type)

    refute has_element?(view, "[data-testid='invitations-truncated']")

    insert_invitations(ctx.user, type, 1)
    view = open_editor(ctx.conn, type)

    assert has_element?(
             view,
             "[data-testid='invitations-truncated']",
             "Showing the latest 100 invitations."
           )

    assert view
           |> render()
           |> Floki.parse_document!()
           |> Floki.find("#{panel(type)} li[id^='invitation-']")
           |> length() ==
             100
  end

  test "an invitation-only type needs no username, a listed one does", ctx do
    ctx.profile |> Changeset.change(username: nil) |> Repo.update!()
    invite_only = insert(:meeting_type, user: ctx.user, invitation_only: true)
    listed = insert(:meeting_type, user: ctx.user)

    view = open_editor(ctx.conn, listed)
    assert has_element?(view, "[data-testid='visibility-needs-username']")

    view = open_editor(ctx.conn, invite_only)
    refute has_element?(view, "[data-testid='visibility-needs-username']")
  end
end
