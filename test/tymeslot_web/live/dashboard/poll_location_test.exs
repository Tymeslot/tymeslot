defmodule TymeslotWeb.Dashboard.PollLocationTest do
  @moduledoc """
  The poll's location as the host sets it: the create form's choices (a
  video call, a saved location, a place typed in), the meeting type's
  location named while the poll has none of its own, and the editor of an
  open poll.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @form "form[phx-submit='create_poll']"
  @editor "[data-testid='poll-details-form']"

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "placehost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    venue = insert(:venue, user: user, name: "Harbour Hall", description: nil)
    video = insert(:video_integration, user: user, name: "Team Talk", is_active: true)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user, venue: venue, video: video}
  end

  defp open_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> element("button", "New poll") |> render_click()
    view |> element("button", "Add time") |> render_click()
    view
  end

  defp poll_params(extra) do
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    Map.merge(
      %{
        "title" => "Board dinner",
        "duration" => "60",
        "timezone" => "Etc/UTC",
        "slots" => %{"0" => "#{date}T18:00"}
      },
      extra
    )
  end

  # The location, like the form's other pickers, posts from a hidden input
  # the test cannot fill in; its value goes with the event instead.
  @pickers ~w(timezone duration meeting_type_id slots deadline location)

  defp change_form(view, selector, params) do
    {pickers, fields} = Map.split(params, @pickers)
    view |> form(selector, %{"poll" => fields}) |> render_change(%{"poll" => pickers})
  end

  defp submit_form(view, selector, params, extra \\ %{}) do
    {pickers, fields} = Map.split(params, @pickers)

    view
    |> form(selector, %{"poll" => fields})
    |> render_submit(Map.merge(%{"poll" => pickers}, extra))
  end

  defp only_poll(user) do
    [poll] = Polls.list_polls(user.id)
    Repo.get!(PollSchema, poll.id)
  end

  describe "the create form" do
    test "offers the host's video integrations, saved locations and a place of their own",
         %{conn: conn, venue: venue, video: video} do
      view = open_form(conn)

      assert has_element?(
               view,
               "select[data-name='poll[location]'] option[value='']",
               "No location"
             )

      assert has_element?(
               view,
               "select[data-name='poll[location]'] option[value='video:#{video.id}']",
               "Team Talk"
             )

      assert has_element?(
               view,
               "select[data-name='poll[location]'] option[value='venue:#{venue.id}']",
               "Harbour Hall"
             )

      assert has_element?(view, "select[data-name='poll[location]'] option[value='custom']")
      refute has_element?(view, "input[name='poll[location_details]']")
    end

    test "saves a saved location with the poll", %{conn: conn, user: user, venue: venue} do
      view = open_form(conn)

      submit_form(view, @form, poll_params(%{"location" => "venue:#{venue.id}"}))

      poll = only_poll(user)
      assert poll.location_kind == :in_person
      assert poll.venue_id == venue.id
    end

    test "asks for the place once the host picks their own, and saves it",
         %{conn: conn, user: user} do
      view = open_form(conn)

      change_form(view, @form, poll_params(%{"location" => "custom"}))
      assert has_element?(view, "input[name='poll[location_details]']")

      view
      |> form(@form, %{
        "poll" => poll_params(%{"location" => "custom", "location_details" => "Garden pavilion"})
      })
      |> render_submit()

      poll = only_poll(user)
      assert poll.location_kind == :custom
      assert poll.location_details == "Garden pavilion"
    end

    test "a place of their own left empty is pointed out where it is typed",
         %{conn: conn, user: user} do
      view = open_form(conn)
      change_form(view, @form, poll_params(%{"location" => "custom"}))

      submit_form(view, @form, poll_params(%{"location" => "custom", "location_details" => ""}))

      assert Polls.list_polls(user.id) == []
      assert has_element?(view, "[data-testid='poll-location'] [role='alert']")
    end

    test "saves a video call with the poll", %{conn: conn, user: user, video: video} do
      view = open_form(conn)

      submit_form(view, @form, poll_params(%{"location" => "video:#{video.id}"}))

      assert %{location_kind: :video, video_integration_id: id} = only_poll(user)
      assert id == video.id
    end

    test "names the meeting type's location while the poll has none of its own",
         %{conn: conn, user: user, venue: venue} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Dinner",
          locations: [in_person_location([venue])]
        )

      view = open_form(conn)

      change_form(view, @form, %{"meeting_type_id" => "#{meeting_type.id}"})

      assert has_element?(
               view,
               "select[data-name='poll[location]'] option[value='']",
               "From the meeting type: Harbour Hall"
             )
    end

    test "a draft opens with the location it was saved with", %{conn: conn, user: user} do
      view = open_form(conn)
      change_form(view, @form, poll_params(%{"location" => "custom"}))

      view
      |> form(@form, %{
        "poll" => poll_params(%{"location" => "custom", "location_details" => "Boathouse"})
      })
      |> render_submit(%{"intent" => "draft"})

      draft = only_poll(user)
      assert draft.status == :draft

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("[data-testid='edit-draft']") |> render_click()

      assert has_element?(
               view,
               "select[data-name='poll[location]'] option[value='custom'][selected]"
             )

      assert has_element?(view, "input[name='poll[location_details]'][value='Boathouse']")
    end
  end

  describe "the editor of an open poll" do
    setup %{user: user} do
      poll = insert(:poll, user: user, status: :open, title: "Board dinner")
      start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)
      insert(:poll_time_slot, poll: poll, start_time: start, end_time: DateTime.add(start, 3600))
      %{poll: poll}
    end

    defp open_editor(conn, poll) do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("button[phx-click='edit_poll_details']") |> render_click()
      view
    end

    test "changes where the meeting will be held", %{conn: conn, poll: poll, venue: venue} do
      view = open_editor(conn, poll)

      submit_form(view, @editor, %{"location" => "venue:#{venue.id}"})

      assert %{location_kind: :in_person, venue_id: venue_id} = Repo.get!(PollSchema, poll.id)
      assert venue_id == venue.id
    end

    test "opens on the poll's own location", %{conn: conn, poll: poll} do
      poll
      |> Changeset.change(location_kind: :custom, location_details: "Boathouse")
      |> Repo.update!()

      view = open_editor(conn, poll)

      assert has_element?(
               view,
               "#{@editor} select[data-name='poll[location]'] option[value='custom'][selected]"
             )

      assert has_element?(
               view,
               "#{@editor} input[name='poll[location_details]'][value='Boathouse']"
             )
    end
  end
end
