defmodule TymeslotWeb.Dashboard.PollDraftsTest do
  @moduledoc """
  The host's side of a draft poll: saving the create form as a draft,
  finding it in the list without a link, coming back to it as they left it,
  and publishing it, which invites the people it lists.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestHelpers.Eventually
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  # The calendar conflict check runs in a task of its own.
  setup :set_mox_global

  setup do
    TestMocks.setup_calendar_mocks()
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile,
        user: user,
        username: "host#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC"
      )

    insert(:calendar_integration, user: user, provider: "debug")
    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
    {:ok, conn: conn, user: user, profile: profile, date: date}
  end

  defp form_params(date, overrides) do
    %{
      "poll" =>
        Map.merge(
          %{
            "title" => "Launch planning",
            "duration" => "30",
            "timezone" => "Etc/UTC",
            "slots" => %{"0" => "#{date}T09:00"},
            "invitees" => "Grace Hopper <grace@example.com>"
          },
          overrides
        )
    }
  end

  defp open_new_form(view) do
    view |> element("button", "New poll") |> render_click()
    view |> element("button", "Add time") |> render_click()
    view
  end

  defp submit(view, params, intent) do
    view
    |> form("form[phx-submit='create_poll']", params)
    |> render_submit(%{"intent" => intent})
  end

  test "Save draft keeps the poll without inviting anyone, and lists it without a link", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")

    assert [%{status: :draft} = draft] = Polls.list_polls(user.id)
    assert draft.participants == []
    refute_enqueued(worker: EmailWorker)

    refute has_element?(view, "form[phx-submit='create_poll']")
    assert has_element?(view, "[data-testid='poll-status']", "Draft")
    assert has_element?(view, "[data-testid='edit-draft']")
    refute has_element?(view, "#poll-copy-#{draft.id}")
  end

  test "a saved draft opens in the form as the host left it", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    [draft] = Polls.list_polls(user.id)

    view |> element("[data-testid='edit-draft']") |> render_click()

    assert has_element?(view, "input[name='poll[title]'][value='Launch planning']")
    assert has_element?(view, "input[name='poll[slots][0]'][value='#{date}T09:00']")

    assert has_element?(
             view,
             "textarea[name='poll[invitees]']",
             "Grace Hopper <grace@example.com>"
           )

    assert has_element?(view, "[data-testid='publish-poll']", "Publish poll")
    assert has_element?(view, "[data-testid='delete-draft']")
    refute has_element?(view, "#poll-results-#{draft.id}")
    assert draft.status == :draft
  end

  test "publishing a draft opens it and invites the people it lists", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    view |> element("[data-testid='edit-draft']") |> render_click()

    submit(view, form_params(date, %{"title" => "Launch review"}), "publish")

    assert [%{status: :open, title: "Launch review"} = poll] = Polls.list_polls(user.id)
    assert [grace] = poll.participants
    assert grace.email == "grace@example.com"

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_poll_invitation", "participant_id" => grace.id}
    )

    assert has_element?(view, "[data-testid='poll-status']", "Open")
  end

  test "a draft whose deadline has passed is not published, and says why", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    soon = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
    deadline = soon |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
    view |> open_new_form() |> submit(form_params(date, %{"deadline" => deadline}), "draft")

    [draft] = Polls.list_polls(user.id)
    passed = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
    Repo.update!(Changeset.change(draft, deadline_at: passed))

    view |> element("[data-testid='edit-draft']") |> render_click()
    shown = passed |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
    html = submit(view, form_params(date, %{"deadline" => shown}), "publish")

    assert html =~ "must be in the future"
    assert [%{status: :draft}] = Polls.list_polls(user.id)
  end

  test "deleting a draft asks first, then removes it", %{conn: conn, user: user, date: date} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    view |> element("[data-testid='edit-draft']") |> render_click()

    view |> element("[data-testid='delete-draft']") |> render_click()
    assert has_element?(view, "#delete-poll-modal", "Delete this draft")
    assert Polls.list_polls(user.id) != []

    view |> element("[data-testid='confirm-delete-poll']", "Delete draft") |> render_click()

    assert Polls.list_polls(user.id) == []
  end

  test "a draft published from another tab closes here, saying so, with its delete prompt", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    view |> element("[data-testid='edit-draft']") |> render_click()
    view |> element("[data-testid='delete-draft']") |> render_click()
    assert has_element?(view, "#delete-poll-modal", "Delete this draft")

    [draft] = Polls.list_polls(user.id)
    {:ok, start_time, 0} = DateTime.from_iso8601("#{date}T09:00:00Z")

    {:ok, _poll} =
      Polls.publish_draft(draft.id, user.id, %{
        title: draft.title,
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [%{start_time: start_time}],
        invitees: [%{email: "grace@example.com", name: "Grace Hopper"}]
      })

    # The broadcast reaches the form in hops (the LiveView, the component,
    # then the flash), so wait for the last to land.
    eventually(fn ->
      assert render(view) =~ "This draft has already been published or deleted."
    end)

    refute has_element?(view, "form[phx-submit='create_poll']")
    refute has_element?(view, "#delete-poll-modal", "Delete this draft")
    assert has_element?(view, "#poll-results-#{draft.id}")
    assert has_element?(view, "[data-testid='poll-status']", "Open")
    assert {:ok, %{status: :open}} = Polls.get_poll_for_host(draft.id, user.id)
  end

  test "a draft deleted from another tab closes here, saying so, and leaves the list", %{
    conn: conn,
    user: user,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    view |> element("[data-testid='edit-draft']") |> render_click()

    [draft] = Polls.list_polls(user.id)
    :ok = Polls.delete_poll(draft.id, user.id)

    # The broadcast reaches the form in hops (the LiveView, the component,
    # then the flash), so wait for the last to land.
    eventually(fn ->
      assert render(view) =~ "This draft has already been published or deleted."
    end)

    refute has_element?(view, "form[phx-submit='create_poll']")
    refute has_element?(view, "[data-testid='edit-draft']")
  end

  test "publishing a draft from its own form says nothing of another tab", %{
    conn: conn,
    date: date
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> open_new_form() |> submit(form_params(date, %{}), "draft")
    view |> element("[data-testid='edit-draft']") |> render_click()

    submit(view, form_params(date, %{}), "publish")

    refute render(view) =~ "This draft has already been published or deleted."
  end

  test "warns about a time that clashes with an event in the calendar", %{conn: conn, date: date} do
    {:ok, busy_day} = Date.from_iso8601(date)

    TestMocks.setup_calendar_mocks(
      events: [
        %{
          summary: "Dentist",
          start_time: DateTime.new!(busy_day, ~T[09:00:00], "Etc/UTC"),
          end_time: DateTime.new!(busy_day, ~T[10:00:00], "Etc/UTC")
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    open_new_form(view)
    view |> element("button", "Add time") |> render_click()

    params = form_params(date, %{"slots" => %{"0" => "#{date}T09:00", "1" => "#{date}T14:00"}})
    view |> form("form[phx-submit='create_poll']", params) |> render_change()
    render_async(view)

    assert has_element?(view, "[data-testid='poll-slot-conflict-warning'][data-slot-key='0']")
    refute has_element?(view, "[data-testid='poll-slot-conflict-warning'][data-slot-key='1']")
  end
end
