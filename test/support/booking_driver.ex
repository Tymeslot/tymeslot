defmodule TymeslotWeb.BookingDriver do
  @moduledoc """
  Drives a booking page in a `Phoenix.LiveViewTest` view through the markup
  contract alone (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"The markup contract"),
  so one walk books on every theme, whatever its journey and its markup:

    * `data-fact="meeting_type"`, `data-value` the meeting type's slug;
    * `data-fact="date"`, `data-value` an ISO date, then `data-fact="time"`,
      `data-value` the time as `select_time` sends it;
    * `data-fact="slot"`, `data-date` and `data-time`: a day and a time in
      one click;
    * `data-fact="answer"`, `data-question` the question id: a `<form>` for a
      question typed into, whose input is named `value` (the shared question
      inputs' name, which `answer/3` fills), or each choice with its
      `data-value`;
    * `form[data-fact="attendee"]`, the booking form;
    * `data-intent` on the controls that move: `continue`, `back`, `submit`,
      `restart`, `earlier` and `later` on a picker's period arrows, and
      `edit` (an answered moment's Edit, `phx-value-step` the moment's key).

  Finding and clicking go through those attributes only. Waiting does not:
  nothing on a page says that the month's availability has arrived or that
  a week of slots has been fetched, so the waits read the LiveView's
  assigns, as the flow's own tests do. LiveViewTest runs no client
  bindings, so `load/1` sends the pushes a page's `phx-mounted` bindings
  carry, as a browser does on mount (the shared `WeekGrid` asks for its
  week this way).

  A day past the picker's window is brought into view through
  `data-intent="later"`, clicked until the day is shown; a picker that
  renders no enabled `later` fails the pick by name.

  A page that moves on by itself renders no way on: there `continue/1`
  checks, through `data-moment` and `data-moment-state` on the moments'
  roots, that the next moment opened. A page that defaulted the meeting type
  renders no choice: there `choose_meeting_type/2` reads the type the
  booking holds (`:selected_duration`) and does nothing when it is the one
  asked for.

  `book/2` composes the steps in the order the page asks for them; the other
  functions are the steps, for a test that drives one itself. Reading the
  page and waiting on it live in `TymeslotWeb.BookingDriver.Page`.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest
  import TymeslotWeb.BookingDriver.Page

  alias Phoenix.LiveViewTest.View

  @meeting_type "[data-fact='meeting_type']"
  @date "[data-fact='date']"
  @time "[data-fact='time']"
  @slot "[data-fact='slot']"
  @answer "[data-fact='answer']"
  @attendee "form[data-fact='attendee']"
  @continue "[data-intent='continue']"
  @back "[data-intent='back']"
  @edit "[data-intent='edit']"
  @restart "[data-intent='restart']"
  @earlier "[data-intent='earlier']"
  @later "[data-intent='later']"
  @enabled ":not([disabled])"

  @max_periods 6
  @max_moves 24
  @outcome_wait_ms 10_000

  @default_attendee %{name: "Test Booker", email: "booker@example.com", message: ""}

  @typedoc "Booking form fields by the form's own names: `:name`, `:email`, `:message`."
  @type attendee :: %{optional(atom()) => String.t()}

  # The meeting type

  @doc "The meeting types the page offers: their `data-value`s, in page order."
  @spec meeting_types(View.t()) :: [String.t()]
  def meeting_types(view), do: attribute(view, @meeting_type, "data-value")

  @doc """
  Chooses the meeting type whose `data-value` is `duration` (its slug). On a
  page that renders no meeting-type choice because the booking already holds
  `duration` (a journey that defaults an organiser's single type), it does
  nothing; with no choice rendered and another type, or none, held, it fails.
  """
  @spec choose_meeting_type(View.t(), String.t()) :: :ok
  def choose_meeting_type(view, duration) do
    case choice_move(render(view), assigns(view)[:selected_duration], duration) do
      :click ->
        offered = meeting_types(view)

        unless duration in offered,
          do:
            flunk(
              "BookingDriver.choose_meeting_type/2: the page offers no meeting type " <>
                "#{inspect(duration)} (offered: #{inspect(offered)})"
            )

        remember(view)
        view |> element("#{@meeting_type}[data-value='#{duration}']") |> render_click()
        sync(view)

      :chosen ->
        :ok

      {:stuck, reason} ->
        flunk("BookingDriver.choose_meeting_type/2: " <> reason)
    end
  end

  @doc """
  What `choose_meeting_type/2` does on the page `html`, `chosen` being the
  meeting type the booking holds (`:selected_duration`): `:click` while the
  page renders a meeting-type choice; `:chosen` when it renders none and
  `duration` is the type held; otherwise `{:stuck, reason}`. Public so the
  driver's tests pin the decision without a page of each kind.
  """
  @spec choice_move(String.t(), String.t() | nil, String.t()) ::
          :click | :chosen | {:stuck, String.t()}
  def choice_move(html, chosen, duration) do
    cond do
      html |> Floki.parse_document!() |> Floki.find(@meeting_type) != [] ->
        :click

      chosen == duration ->
        :chosen

      true ->
        {:stuck,
         "the page renders no meeting-type choice and holds #{inspect(chosen)}, " <>
           "not #{inspect(duration)}"}
    end
  end

  # The slot

  @doc """
  Readies a slot picker as a browser would: waits for the month's
  availability, sends the pushes of the page's `phx-mounted` bindings to the
  components they target, and waits for the week of slots they fetch. Every
  pick calls it; a test calls it itself only to read a picker before picking.
  """
  @spec load(View.t()) :: :ok
  def load(view) do
    wait(
      fn -> assigns(view)[:availability_status] in [:loaded, :error] end,
      "the page's availability never finished loading"
    )

    for {event, cid} <- new_mounted_pushes(view) do
      view |> with_target("[data-phx-component='#{cid}']") |> render_click(event, %{})
    end

    settle(view)
  end

  @doc """
  Picks the day `iso` (an ISO 8601 date) on a picker of days. A day past
  those on show is brought into view by clicking `data-intent="later"` until
  it is shown (one before them, `"earlier"`), at most #{@max_periods}
  times; with no enabled control to click, the pick fails by name. The
  day's times arrive after it; `pick_time/2` waits for them.
  """
  @spec pick_date(View.t(), String.t()) :: :ok
  def pick_date(view, iso) do
    load(view)
    marks_slot_fact!(view)
    show(view, iso, @date, "data-value", @max_periods)
    click(view, "#{@date}[data-value='#{iso}']")
  end

  @doc "Picks the time whose `data-value` is `time`, once the chosen day's times are on show."
  @spec pick_time(View.t(), String.t()) :: :ok
  def pick_time(view, time), do: click(view, "#{@time}[data-value='#{time}']")

  @doc """
  Picks `time` on the day `iso`: the one `data-fact="slot"` button for both
  where the page shows slot buttons, else the day, then the time. A day
  outside the window on show is brought into view as `pick_date/2` does.
  """
  @spec pick_slot(View.t(), String.t(), String.t()) :: :ok
  def pick_slot(view, iso, time) do
    load(view)
    marks_slot_fact!(view)

    if has_element?(view, @slot) do
      show(view, iso, @slot, "data-date", @max_periods)
      click(view, "#{@slot}[data-date='#{iso}'][data-time='#{time}']")
    else
      pick_date(view, iso)
      pick_time(view, time)
    end
  end

  @doc """
  Picks the first free time the page offers, moving on a period at a time
  (at most #{@max_periods}) while the period on show has none, or with
  `on: iso` the first free time on that day. Returns `{iso_date, time}`.
  """
  @spec pick_first_slot(View.t(), keyword()) :: {String.t(), String.t()}
  def pick_first_slot(view, opts \\ []) do
    load(view)
    marks_slot_fact!(view)

    case Keyword.get(opts, :on) do
      nil ->
        first_free(view, @max_periods)

      iso ->
        if has_element?(view, @slot) do
          show(view, iso, @slot, "data-date", @max_periods)
          {iso, first_time_on(view, iso)}
        else
          pick_date(view, iso)
          {iso, pick_first_time(view)}
        end
    end
  end

  # Questions

  @doc """
  Answers the question `question_id`: fills its form's input named `value`
  when it is typed into, or clicks the choice whose `data-value` is `value`
  (each one, for a list).
  """
  @spec answer(View.t(), String.t(), term()) :: :ok
  def answer(view, question_id, value) do
    question = "#{@answer}[data-question='#{question_id}']"

    cond do
      has_element?(view, "form" <> question) ->
        remember(view)
        view |> form("form" <> question, %{"value" => value}) |> render_change()
        sync(view)

      is_list(value) ->
        Enum.each(value, &click(view, "#{question}[data-value='#{&1}']"))

      true ->
        click(view, "#{question}[data-value='#{value}']")
    end
  end

  # Moving

  @doc """
  Takes the way on (`data-intent="continue"`), once it is enabled. A page
  that renders none moves on by itself (a `Continuous` or `Transcript`
  journey opens the next moment once a moment's facts are known): there it
  asserts that the next moment has opened, and fails otherwise.
  """
  @spec continue(View.t()) :: :ok
  def continue(view) do
    last = last_moment(view)

    wait(
      fn -> continue_move(render(view), last) in [:click, :opened] end,
      "the page neither offered a way on (data-intent=\"continue\") " <>
        "nor opened the next moment by itself"
    )

    case continue_move(render(view), last) do
      :click ->
        click(view, @continue)

      # The move is used up: a second `continue/1` with no action between
      # must see the page move on again, not this move once more.
      :opened ->
        remember(view)

      {:stuck, reason} ->
        flunk("BookingDriver.continue/1: " <> reason)
    end
  end

  @doc """
  What `continue/1` does on the page `html`, `last` being the moment that was
  current before the driver's last action on the view (`nil` when it has not
  acted, or the page marks no moments):

    * `:opened` - the page has moved on by itself since that action: the
      moment `last` is now marked done (`data-moment-state="done"`) and
      another is current. A way on the newly opened moment renders is not
      taken (it belongs to that moment, which has asked nothing yet);
    * `:click` - otherwise, the page renders a way on
      (`data-intent="continue"`), enabled or about to be;
    * `:opened` - with no `last`, no way on, and a done moment before the
      current one (a page that defaulted a fact as it opened);
    * `{:stuck, reason}` - none of these.

  Public so the driver's tests pin the decision without a page of each kind.
  """
  @spec continue_move(String.t(), String.t() | nil) :: :click | :opened | {:stuck, String.t()}
  def continue_move(html, last) do
    doc = Floki.parse_document!(html)
    moments = moments(doc)

    cond do
      last != nil and moved_on?(moments, last) ->
        :opened

      Floki.find(doc, @continue) != [] ->
        :click

      moved_on?(moments, last) ->
        :opened

      true ->
        {:stuck,
         "no way on (data-intent=\"continue\") and no moment opened after " <>
           "#{inspect(last)} (moments: #{inspect(moments)})"}
    end
  end

  @doc "Takes the way back (`data-intent=\"back\"`)."
  @spec back(View.t()) :: :ok
  def back(view), do: click(view, @back)

  @doc """
  Edits an answered moment: presses its `data-intent="edit"` control, which
  sends `navigate_to_step` with the moment's key, so the navigator forgets
  what the moment collected and every fact depending on it
  (`Navigators.Transcript`).
  """
  @spec edit(View.t(), atom() | String.t()) :: :ok
  def edit(view, moment), do: click(view, "#{@edit}[phx-value-step='#{moment}']")

  @doc "Starts a fresh booking from an outcome (`data-intent=\"restart\"`)."
  @spec restart(View.t()) :: :ok
  def restart(view), do: click(view, @restart)

  # The attendee

  @doc "Types `attrs` into the booking form, as the visitor typing would (`phx-change`)."
  @spec fill_attendee(View.t(), attendee()) :: :ok
  def fill_attendee(view, attrs) do
    view |> form(@attendee, %{"booking" => booking_params(attrs)}) |> render_change()
    sync(view)
  end

  @doc """
  Submits the booking form with `attrs` over what it holds. Returns the page
  once the LiveView has handled the submission, or the redirect a submission
  that leaves the page (a paid booking) answers with.
  """
  @spec submit(View.t(), attendee()) :: String.t() | {:error, term()}
  def submit(view, attrs \\ %{}) do
    case view |> form(@attendee, %{"booking" => booking_params(attrs)}) |> render_submit() do
      html when is_binary(html) ->
        sync(view)
        render(view)

      redirect ->
        redirect
    end
  end

  # The whole booking

  @doc """
  Books on whatever page `view` shows, doing what the page asks for next:
  the meeting type (`:meeting_type`, else the first offered), the slot
  (`:date` and `:time`; the first free time on `:date` when only that is
  given; else the first free time), each question on show (`:answers`, a
  map of question id to value; a question with no entry is left as it is),
  then the way on, until the page asks for the attendee. There it stops
  (`until: :attendee`), or submits `:attendee` (default
  `#{inspect(@default_attendee)}`) and returns what `submit/2` returned
  (`until: :submitted`), or waits for the outcome's fresh start
  (`until: :confirmation`, the default) and returns the page.
  """
  @spec book(View.t(), keyword()) :: String.t() | {:error, term()}
  def book(view, opts \\ []), do: drive(view, opts, MapSet.new(), @max_moves)

  defp drive(_view, _opts, done, 0) do
    flunk(
      "BookingDriver.book/2 moved #{@max_moves} times without reaching the attendee form " <>
        "(done: #{inspect(MapSet.to_list(done))}); a required question with no answer " <>
        "in :answers keeps the page where it is"
    )
  end

  defp drive(view, opts, done, moves_left) do
    case next_ask(view, done, opts[:meeting_type]) do
      :attendee ->
        finish(view, opts)

      ask ->
        do_ask(view, ask, opts)
        drive(view, opts, mark(done, ask), moves_left - 1)
    end
  end

  # A meeting type asked for by name is checked even where the page renders
  # no choice (a defaulted type): once the page asks for anything that needs
  # it, `choose_meeting_type/2` confirms that the booking holds that type.
  defp next_ask(view, done, wanted) do
    ask =
      cond do
        :meeting_type not in done and has_element?(view, @meeting_type) -> :meeting_type
        :slot not in done and slot_picker?(view) -> :slot
        true -> question_or_attendee(view, done)
      end

    if ask not in [:meeting_type, :continue] and :meeting_type not in done and wanted != nil,
      do: :meeting_type,
      else: ask
  end

  defp question_or_attendee(view, done) do
    case pending_question(view, done) do
      nil -> if has_element?(view, @attendee), do: :attendee, else: :continue
      question -> {:answer, question}
    end
  end

  defp do_ask(view, :meeting_type, opts),
    do: choose_meeting_type(view, opts[:meeting_type] || first_meeting_type(view))

  defp do_ask(view, :slot, opts), do: book_slot(view, opts[:date], opts[:time])

  defp do_ask(view, {:answer, question}, opts) do
    case Map.fetch(Keyword.get(opts, :answers, %{}), question) do
      {:ok, value} -> answer(view, question, value)
      :error -> :ok
    end
  end

  defp do_ask(view, :continue, _opts), do: continue(view)

  defp mark(done, :continue), do: done
  defp mark(done, ask), do: MapSet.put(done, ask)

  defp book_slot(view, nil, _time), do: pick_first_slot(view)
  defp book_slot(view, iso, nil), do: pick_first_slot(view, on: iso)
  defp book_slot(view, iso, time), do: pick_slot(view, iso, time)

  defp finish(view, opts) do
    attendee = Keyword.get(opts, :attendee, @default_attendee)

    case Keyword.get(opts, :until, :confirmation) do
      :attendee ->
        render(view)

      :submitted ->
        submit(view, attendee)

      :confirmation ->
        _page = submit(view, attendee)

        wait(
          fn -> has_element?(view, @restart) end,
          "the booking never reached an outcome offering a fresh start",
          @outcome_wait_ms
        )

        render(view)
    end
  end

  defp first_meeting_type(view) do
    case meeting_types(view) do
      [duration | _rest] -> duration
      [] -> flunk("the page offers no meeting type")
    end
  end

  # A page is a slot picker when it shows a day or a slot control, before or
  # after `load/1` runs its mounted pushes (a week grid shows its slots only
  # once it has asked for its week).
  defp slot_picker?(view) do
    shows_picker?(view) or
      (mounted_pushes(view) != [] and load(view) == :ok and shows_picker?(view))
  end

  defp shows_picker?(view), do: has_element?(view, "#{@date}, #{@slot}")

  defp pending_question(view, done) do
    view
    |> attribute(@answer, "data-question")
    |> Enum.uniq()
    |> Enum.find(&({:answer, &1} not in done))
  end

  # Pickers

  # The first free slot button on show, else the first free day and its
  # first time, else the next period.
  defp first_free(_view, 0),
    do: flunk("no free time within #{@max_periods} periods of the picker")

  defp first_free(view, periods_left) do
    case {first_node(view, @slot <> @enabled), attribute(view, @date <> @enabled, "data-value")} do
      {nil, []} ->
        move(view, @later)
        first_free(view, periods_left - 1)

      {nil, [iso | _rest]} ->
        click(view, "#{@date}[data-value='#{iso}']")
        {iso, pick_first_time(view)}

      {node, _days} ->
        {iso, time} = slot_of(node)
        click(view, "#{@slot}[data-date='#{iso}'][data-time='#{time}']")
        {iso, time}
    end
  end

  defp slot_of(node) do
    case {Floki.attribute(node, "data-date"), Floki.attribute(node, "data-time")} do
      {[iso], [time]} ->
        {iso, time}

      _missing ->
        flunk(
          "a data-fact=\"slot\" button lacks its data-date or data-time: " <>
            Floki.raw_html(node)
        )
    end
  end

  defp marks_slot_fact!(view) do
    unless shows_picker?(view),
      do: flunk("the slot moment marks no day (data-fact=date) and no slot (data-fact=slot)")

    :ok
  end

  defp pick_first_time(view) do
    wait(fn -> has_element?(view, @time <> @enabled) end, "no time came up for the chosen day")
    [time | _rest] = attribute(view, @time <> @enabled, "data-value")
    pick_time(view, time)
    time
  end

  defp first_time_on(view, iso) do
    case attribute(view, "#{@slot}[data-date='#{iso}']#{@enabled}", "data-time") do
      [time | _rest] ->
        click(view, "#{@slot}[data-date='#{iso}'][data-time='#{time}']")
        time

      [] ->
        flunk("#{iso} has no free time on the page")
    end
  end

  # Brings `iso` into view: on show already, or moved towards through the
  # picker's arrows, comparing it with the dates on show (ISO dates order as
  # strings). A date inside the range on show with no control of its own is
  # left for the click that follows to fail on, by name.
  defp show(view, iso, selector, attr, periods_left) do
    shown = attribute(view, selector, attr)

    cond do
      iso in shown ->
        :ok

      shown == [] or periods_left == 0 ->
        flunk("#{iso} never came into view on the picker")

      iso > Enum.max(shown) ->
        move(view, @later)
        show(view, iso, selector, attr, periods_left - 1)

      iso < Enum.min(shown) ->
        move(view, @earlier)
        show(view, iso, selector, attr, periods_left - 1)

      true ->
        :ok
    end
  end

  defp move(view, intent) do
    unless has_element?(view, intent <> @enabled),
      do: flunk("the picker offers no enabled #{intent} to move on with")

    view |> element(intent <> @enabled) |> render_click()
    sync(view)
    load(view)
  end

  # Plumbing

  defp click(view, selector) do
    wait(
      fn -> has_element?(view, selector <> @enabled) end,
      "the page never showed an enabled #{selector}"
    )

    remember(view)
    view |> element(selector <> @enabled) |> render_click()
    sync(view)
  end

  defp booking_params(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
