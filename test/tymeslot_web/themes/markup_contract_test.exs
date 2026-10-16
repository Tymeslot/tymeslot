defmodule TymeslotWeb.Themes.MarkupContractTest do
  @moduledoc """
  The markup contract (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"The markup
  contract") on every registered theme's booking page: each moment, while it
  is on screen, marks every fact it collects that the booking needs, and
  the page marks its ways on. `TymeslotWeb.BookingDriver` finds a page's
  controls by these attributes alone, so a theme that keeps them gets every
  shared flow suite without a driver of its own.

  The walk follows the theme's own journey (`socket.assigns.journey`) a
  moment at a time, so a journey that groups the facts differently is held
  to the same contract, and moves on as the driver does: through the way on
  where the theme renders one, else by the next moment opening by itself.
  The organiser offers two meeting types and the one booked asks two
  questions, so the meeting-type and answers facts are required wherever a
  journey collects them; a moment's questions are all answered, however
  many it shows at a time, before the walk leaves it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :scheduling
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "Etc/UTC"
  @max_moments 12
  @answers %{"mc-company" => "Acme Corp", "mc-recorded" => true}

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme <- ThemeTestMatrix.registered() do
    @tag :capture_log
    test "#{theme.name}: every moment marks the facts it collects", %{conn: conn} do
      %{user: user, profile: profile} =
        seed_booking_account(unquote(theme.id), "contract-#{unquote(theme.slug)}", @timezone)

      asked = ask_questions(user)
      insert(:meeting_type, user: user, duration_minutes: 60, name: "Long Chat", is_active: true)

      ctx = %{
        offered:
          user |> meeting_types() |> Enum.map(&MeetingTypes.effective_slug/1) |> Enum.sort(),
        booked: MeetingTypes.effective_slug(asked)
      }

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

      seen = view |> walk(ctx, [], @max_moments) |> List.flatten() |> Enum.uniq() |> Enum.sort()

      assert seen == [:answers, :attendee, :meeting_type, :slot]
    end
  end

  # One moment at a time: the current moment marks what it collects, then the
  # walk does what it asks and moves on as `BookingDriver.continue/1` does (the
  # way on where the theme renders one, else the next moment having opened by
  # itself), until an outcome is on screen.
  defp walk(_view, _ctx, _seen, 0), do: flunk("the walk never reached an outcome")

  defp walk(view, ctx, seen, moments_left) do
    assigns = live_assigns(view)

    case Enum.find(assigns.journey.moments, &(&1.key == assigns.current_state)) do
      nil ->
        assert has_element?(view, "[data-intent='restart']"),
               "the #{inspect(assigns.current_state)} outcome offers no fresh start"

        seen

      moment ->
        facts =
          Enum.filter(moment.collects, fn fact ->
            Map.fetch!(Journey.facts(), fact).required?(assigns)
          end)

        Enum.each(facts, &check_and_do(view, &1, ctx, assigns))

        # The way on where the theme renders one; else the driver asserts that
        # the next moment opened by itself, and fails by name if it did not.
        unless :attendee in facts, do: BookingDriver.continue(view)

        walk(view, ctx, [facts | seen], moments_left - 1)
    end
  end

  defp check_and_do(view, :meeting_type, ctx, _assigns) do
    assert Enum.sort(attribute(view, "[data-fact='meeting_type']", "data-value")) == ctx.offered,
           "the meeting-type choices are not each marked once with their slug"

    BookingDriver.choose_meeting_type(view, ctx.booked)
  end

  defp check_and_do(view, :slot, _ctx, before) do
    BookingDriver.load(view)
    days = attribute(view, "[data-fact='date']", "data-value")
    slots = slot_pairs(view)

    assert days ++ slots != [], "a moment collecting the slot marks no day and no slot"

    # One control per value, checked on the first period the picker shows.
    assert days == Enum.uniq(days), "two day buttons share a data-value"
    assert slots == Enum.uniq(slots), "two slot buttons share a day and a time"

    assert Enum.all?(days, &match?({:ok, _date}, Date.from_iso8601(&1))),
           "a day button's data-value is not an ISO date"

    {day, time} = BookingDriver.pick_first_slot(view)
    times = attribute(view, "[data-fact='time']", "data-value")

    assert times == Enum.uniq(times), "two time buttons share a data-value"

    # The control clicked said what it sends: the booking holds the day and
    # the time its attributes named.
    assigns = live_assigns(view)

    assert {assigns.selected_date, assigns.selected_time} == {day, time},
           "the time picked is not the day and time its marked control named"

    # The picker marks the time picked among its choices (a time button
    # belongs to the day picked; a slot button names its own) while it is on
    # show, and always while its moment is still the one being answered. A
    # page that answers the moment in its place once the time is picked (a
    # transcript, moving on by itself) may show no picker.
    marked = Enum.map(times, &{day, &1}) ++ slot_pairs(view)
    must_mark = marked != [] or assigns.current_state == before.current_state

    assert {day, time} in marked == must_mark,
           "the time picked is marked neither as a time nor as a slot"
  end

  defp check_and_do(view, :answers, _ctx, _assigns),
    do: answer_all(view, [], map_size(@answers) + 1)

  defp check_and_do(view, :attendee, _ctx, _assigns) do
    # Answers asked beside the details are confirmed by the way on before
    # the form shows.
    if not has_element?(view, "form[data-fact='attendee']") and
         has_element?(view, "[data-intent='continue']"),
       do: BookingDriver.continue(view)

    forms =
      view |> render() |> Floki.parse_document!() |> Floki.find("form[data-fact='attendee']")

    assert length(forms) == 1,
           "the attendee's moment does not render exactly one form[data-fact=attendee]"

    assert has_element?(view, "[data-intent='submit']"), "the attendee's moment has no submit"

    BookingDriver.submit(view, %{name: "Ada Lovelace", email: "contract@example.com", message: ""})

    wait_until(fn -> has_element?(view, "[data-intent='restart']") end, 10_000)
  end

  defp check_and_do(_view, fact, _ctx, _assigns),
    do: flunk("the markup contract has no rule for the #{inspect(fact)} fact; add one here")

  # Every question the moment shows, a round at a time: the question the
  # engine is asking must be marked, and every unanswered question on screen
  # is answered (one, on a page that asks one at a time; several, on one that
  # shows them together). Between rounds the walk takes the way on to the next
  # question; after the last answer it stops, leaving the moment to `walk/4`
  # (a moment that also collects the attendee shows its form then, or once
  # the answers are confirmed with its way on).
  defp answer_all(_view, answered, 0),
    do: flunk("the questions moment kept asking after #{inspect(answered)}")

  defp answer_all(view, answered, rounds_left) do
    question = Engine.current_definition(live_assigns(view).engine)["id"]
    shown = view |> attribute("[data-fact='answer']", "data-question") |> Enum.uniq()

    assert question in shown, "question #{question}, on screen, is not marked"

    answered =
      Enum.reduce(shown -- answered, answered, fn id, acc ->
        BookingDriver.answer(view, id, Map.fetch!(@answers, id))
        [id | acc]
      end)

    if Enum.sort(answered) == @answers |> Map.keys() |> Enum.sort() do
      :ok
    else
      BookingDriver.continue(view)
      answer_all(view, answered, rounds_left - 1)
    end
  end

  defp ask_questions(user) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)

    {:ok, meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => "mc-company",
            "type" => "short_text",
            "label" => "Company",
            "required" => true,
            "position" => 0
          },
          %{
            "id" => "mc-recorded",
            "type" => "yes_no",
            "label" => "May we record the call?",
            "required" => true,
            "position" => 1
          }
        ]
      })

    meeting_type
  end

  defp meeting_types(user),
    do: Repo.all(from(m in MeetingTypeSchema, where: m.user_id == ^user.id))

  defp slot_pairs(view) do
    doc = view |> render() |> Floki.parse_document!()

    for node <- Floki.find(doc, "[data-fact='slot']") do
      {node |> Floki.attribute("data-date") |> List.first(),
       node |> Floki.attribute("data-time") |> List.first()}
    end
  end

  defp attribute(view, selector, name),
    do: view |> render() |> Floki.parse_document!() |> Floki.attribute(selector, name)

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
