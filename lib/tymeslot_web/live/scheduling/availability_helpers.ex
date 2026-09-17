defmodule TymeslotWeb.Live.Scheduling.AvailabilityHelpers do
  @moduledoc """
  The availability fetch lifecycle for the scheduling flow.

  What a page offers is decided by `Tymeslot.Availability.Offer`; this module
  builds the request it answers from the socket (`request/1`), and owns the
  month fetch task: starting it, cancelling a superseded one, and delivering
  its result.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{Calculate, Offer, Schedules}
  alias Tymeslot.Demo

  require Logger

  import Component, only: [assign: 3]

  @doc """
  The `Tymeslot.Availability.Offer` request for what this page is showing.

  Built once here so the month fetch and the slot fetch cannot describe the
  page differently. A plain map, so a fetch task can capture it without
  capturing the socket.
  """
  @spec request(Phoenix.LiveView.Socket.t()) :: Offer.request()
  def request(socket) do
    %{
      profile: socket.assigns.organizer_profile,
      user_timezone: socket.assigns[:user_timezone],
      meeting_type: socket.assigns[:meeting_type],
      demo_mode?: Demo.demo_mode?(socket),
      debug_calendar_module: socket.private[:debug_calendar_module]
    }
  end

  @doc """
  Starts the month availability fetch and marks the socket as loading.

  The result always comes back as a `{ref, result}` message finalised by
  `TymeslotWeb.Themes.Shared.InfoHandlers`, in every environment. There
  is no second finaliser, so no test can pin behaviour production never
  has; see `start_availability_task/1` for the one thing that does vary.
  """
  @spec perform_availability_fetch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def perform_availability_fetch(socket) do
    start_time = System.monotonic_time()

    socket =
      socket
      |> assign(:month_availability_map, :loading)
      |> assign(:availability_status, :loading)
      |> assign(:availability_fetch_start_time, start_time)

    start_availability_task(socket)
  end

  @doc """
  Safely initiates an asynchronous month availability fetch if all requirements are met.
  Cancels any existing fetch task before starting a new one.
  """
  @spec fetch_month_availability_async(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def fetch_month_availability_async(socket) do
    if can_fetch_availability?(socket) do
      socket
      |> maybe_cancel_existing_task()
      |> perform_availability_fetch()
    else
      socket
    end
  end

  @doc """
  Checks if all conditions for fetching availability are met.
  """
  @spec can_fetch_availability?(Phoenix.LiveView.Socket.t()) :: boolean()
  def can_fetch_availability?(socket) do
    socket.assigns[:organizer_user_id] &&
      socket.assigns[:organizer_profile] &&
      socket.assigns[:current_year] &&
      socket.assigns[:current_month]
  end

  # Cancels any existing availability fetch task.
  @spec maybe_cancel_existing_task(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp maybe_cancel_existing_task(socket) do
    socket =
      if old_task = socket.assigns[:availability_task] do
        duration =
          case socket.assigns[:availability_fetch_start_time] do
            nil -> "unknown"
            start -> "#{System.monotonic_time() - start}ns"
          end

        Logger.debug("Cancelling previous availability fetch task due to user navigation",
          duration: duration,
          user_id: Map.get(socket.assigns, :organizer_user_id),
          month: Map.get(socket.assigns, :current_month),
          year: Map.get(socket.assigns, :current_year)
        )

        Task.shutdown(old_task, :brutal_kill)
        assign(socket, :availability_task, nil)
      else
        socket
      end

    # Always clear the ref so a result already in flight for the previous
    # window is ignored when it arrives.
    assign(socket, :availability_task_ref, nil)
  end

  # The fetch runs in a linked task, or inline under the deterministic
  # harness, but *both modes deliver the result identically*: a
  # `{ref, {:ok, map}}` / `{ref, {:error, reason}}` message that
  # `TymeslotWeb.Themes.Shared.InfoHandlers` finalises after `mount` and
  # `handle_params/3` have run. The ref match, the loaded/error
  # transitions, the landing on the first bookable day and its refetch
  # hop are therefore one code path with one ordering, whichever mode is
  # selected — the divergence the two-branch fetch used to introduce was
  # not the concurrency, it was the second finaliser and the second
  # ordering that came with it.
  #
  # `:async_availability_fetch` picks the mode. It defaults to `true`;
  # `config/test.exs` sets it `false` so the result is owned by the test
  # process: a task still in flight when a test ends is killed mid-query
  # and takes the checked-out sandbox connection down with it, failing
  # every test that follows. It is a named behavioural flag rather than
  # an `:environment` comparison so a test can opt *back into* the task
  # path (`AvailabilityAsyncFetchTest` does) instead of the whole suite
  # being locked out of the branch that ships.
  #
  # `Task.async/1` links, so the task's lifetime is exactly the
  # LiveView's: a booker who closes the tab cannot leave a calendar fetch
  # running behind them. The cost of the link is that a fetch which
  # *raises* takes the page down with it rather than arriving as a
  # `:DOWN` — which is why `InfoHandlers` has no `:DOWN` handler.
  defp start_availability_task(socket) do
    # Build the request and the range up front so the closure captures plain
    # values, never the socket.
    request = request(socket)
    duration_minutes = duration_minutes(socket)

    {start_date, end_date} =
      Calculate.display_range(socket.assigns.current_year, socket.assigns.current_month)

    fetch = fn -> Offer.days_in_range(request, start_date, end_date, duration_minutes) end

    if async_fetch?() do
      task = Task.async(fetch)

      socket
      |> assign(:availability_task, task)
      |> assign(:availability_task_ref, task.ref)
    else
      # Same message, same mailbox, same arrival point — just computed
      # by this process instead of a task it would have to wait for.
      ref = make_ref()
      send(self(), {ref, fetch.()})

      socket
      |> assign(:availability_task, nil)
      |> assign(:availability_task_ref, ref)
    end
  end

  defp async_fetch?, do: Application.get_env(:tymeslot, :async_availability_fetch, true)

  @doc """
  The meeting length the flow is operating on, in minutes.

  Resolved by `Tymeslot.Availability.Offer.duration_minutes/2`, the resolver
  the booking and reschedule submits share, so the display path and the
  submit path cannot disagree about the duration or its bound.
  """
  @spec duration_minutes(Phoenix.LiveView.Socket.t()) :: pos_integer()
  def duration_minutes(socket) do
    Offer.duration_minutes(
      socket.assigns[:meeting_type],
      socket.assigns[:duration] || socket.assigns[:selected_duration]
    )
  end

  @doc """
  The slot interval the flow is operating on, in minutes, or nil to use the
  meeting type's own duration.

  Resolved by `Tymeslot.Availability.Schedules.slot_interval_minutes/1`, the
  resolver the submit's scheduling config uses too.
  """
  @spec slot_interval_minutes(Phoenix.LiveView.Socket.t()) :: pos_integer() | nil
  def slot_interval_minutes(socket) do
    Schedules.slot_interval_minutes(socket.assigns[:meeting_type])
  end
end
