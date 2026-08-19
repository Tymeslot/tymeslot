defmodule TymeslotWeb.Live.Scheduling.SchedulingLiveMailboxTest do
  @moduledoc """
  The public booking page is long-lived and reachable by anyone, and its
  process receives more than the messages it defines clauses for: a late reply
  from a task whose result is no longer wanted, or a library that posts to
  whichever process called it. Swoosh's test adapter is one such library.

  An unmatched `handle_info` raises, the theme error boundary catches it, and
  the booker is shown an error page over something that had nothing to do with
  their booking.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "mailboxhost",
        booking_theme: "1",
        timezone: "Etc/UTC"
      )

    insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30, is_active: true)
    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile}
  end

  @tag :capture_log
  test "an unexpected message does not take the booking page down", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    # The shape Swoosh's test adapter posts to whichever process delivered an
    # email, which since the circuit breaker stopped executing work inside its
    # own process can be this LiveView.
    send(view.pid, {:email, :from_some_other_concern})
    send(view.pid, :a_bare_atom_nobody_handles)

    rendered = render(view)

    refute rendered =~ "Theme Error"
    assert rendered =~ "Intro"
  end
end
