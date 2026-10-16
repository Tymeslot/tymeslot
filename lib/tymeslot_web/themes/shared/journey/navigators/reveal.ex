defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal do
  @moduledoc """
  What `Navigators.Continuous` and `Navigators.Transcript` share. Both show
  every moment the booking has reached, in journey order, up to and including
  the first one with a fact still to collect (`Journey.Progress.reached/3`),
  and both open the next moment by themselves once its turn comes, with no
  Next press. They differ in the element the moments sit in and in what going
  back does.

  A moment is opened once while it stays reached (`Runtime.open_moment/3`
  records it in `:journey_opened`); one that stops being reached (the slot
  was forgotten, so the attendee moment closed) is forgotten as open, and
  entered again when it is reached again. Opening a moment can complete it
  (a defaulted meeting type), so `settle/2` repeats until nothing new opens.

  While an outcome is current (`:confirmation`, `:awaiting_payment`) nothing
  is visible and nothing moves: `continue/2`, `back/3` and `settle/2` leave
  the socket alone, so the payment wait ends only through the payment
  webhook.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.{Continuous, Transcript}
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  # The outcomes every journey has. While one is current the page shows the
  # outcome alone (`SchedulingPage`), whatever the moments' facts say.
  @outcomes [:confirmation, :awaiting_payment]

  @doc """
  The moment a route lands on: the outcome for `:confirmation`, the first
  moment collecting the slot for `:schedule`, the first collecting the
  attendee for `:booking`, the first moment otherwise.
  """
  @spec entry(Journey.t(), atom()) :: atom()
  def entry(_journey, :confirmation), do: :confirmation
  def entry(journey, :schedule), do: Progress.moment_for(journey, :slot)
  def entry(journey, :booking), do: Progress.moment_for(journey, :attendee)
  def entry(%Journey{moments: [%Moment{key: key} | _rest]}, _live_action), do: key

  @doc """
  Whether `journey` opens its moments by itself (`Continuous` or
  `Transcript`), so its page holds the visitor's choices on one screen.
  """
  @spec journey?(term()) :: boolean()
  def journey?(%{navigator: navigator}),
    do: navigator in [Continuous, Transcript]

  def journey?(_journey), do: false

  @doc "The moments reached, each with its state; none while an outcome is current."
  @spec visible(Journey.t(), map()) :: [{Moment.t(), Progress.state()}]
  def visible(_journey, %{current_state: state}) when state in @outcomes, do: []
  def visible(journey, assigns), do: Progress.reached(journey, assigns)

  @doc """
  Opens every reached moment not yet open and sets `:current_state` to the
  moment still to complete. Leaves an outcome alone.
  """
  @spec settle(Journey.t(), Socket.t()) :: Socket.t()
  def settle(journey, socket) do
    if Journey.moment(journey, socket.assigns[:current_state]),
      do: reveal(journey, socket, length(journey.moments)),
      else: socket
  end

  @doc """
  Moves on from the current moment: each fact it collects that the booking
  requires runs `continue/1`; an error is a flash, a `:stay` keeps the moment
  (the next question of the questions wizard), all `:done` settle and move
  the focus to the moment now current.
  """
  @spec continue(Journey.t(), Socket.t()) :: {:noreply, Socket.t()}
  def continue(journey, socket) do
    case Journey.moment(journey, socket.assigns[:current_state]) do
      nil -> {:noreply, socket}
      current -> current |> run_continue(socket) |> after_continue(journey, socket)
    end
  end

  @doc """
  Goes back within the current moment (its facts' `back/1`, as the questions
  wizard's previous question), or, when every fact leaves, hands the socket
  to `on_leave`.
  """
  @spec back(Journey.t(), Socket.t(), (Socket.t() -> {:noreply, Socket.t()})) ::
          {:noreply, Socket.t()}
  def back(journey, socket, on_leave) do
    case Journey.moment(journey, socket.assigns[:current_state]) do
      nil ->
        {:noreply, socket}

      current ->
        case run_back(current, socket) do
          {:stay, socket} -> {:noreply, socket}
          {:leave, socket} -> on_leave.(socket)
        end
    end
  end

  @doc "Sets `:journey_focus` to the moment now current when it differs from `before`'s."
  @spec focus_on_change(Socket.t(), Socket.t()) :: Socket.t()
  def focus_on_change(socket, before) do
    if socket.assigns[:current_state] == before.assigns[:current_state],
      do: socket,
      else: assign(socket, :journey_focus, socket.assigns[:current_state])
  end

  defp reveal(journey, socket, budget) do
    reached = Progress.reached(journey, socket.assigns)
    keys = MapSet.new(reached, fn {moment, _state} -> moment.key end)
    opened = MapSet.intersection(socket.assigns[:journey_opened] || MapSet.new(), keys)
    socket = assign(socket, :journey_opened, opened)

    unopened =
      Enum.find(reached, fn {moment, _state} -> not MapSet.member?(opened, moment.key) end)

    # An entry can redirect (the attendee moment with no slot), and the
    # budget bounds the loop by the number of moments.
    if unopened && budget > 0 && is_nil(socket.redirected) do
      {moment, _state} = unopened
      reveal(journey, Runtime.open_moment(socket, moment, %{}), budget - 1)
    else
      assign(socket, :current_state, current_key(reached, socket))
    end
  end

  # The first moment still to complete; with every required fact known (which
  # happens only once the attendee is submitted, and that is an outcome) the
  # last moment reached.
  defp current_key(reached, socket) do
    case Enum.find(reached, &match?({_moment, :current}, &1)) || List.last(reached) do
      {moment, _state} -> moment.key
      nil -> socket.assigns[:current_state]
    end
  end

  defp run_continue(moment, socket) do
    facts = Journey.facts()

    moment
    |> Progress.required(socket.assigns, facts)
    |> Enum.reduce_while({:done, socket}, fn key, {:done, acc} ->
      case Map.fetch!(facts, key).continue(acc) do
        {:done, acc} -> {:cont, {:done, acc}}
        {:stay, acc} -> {:halt, {:stay, acc}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp after_continue({:done, socket}, journey, before),
    do: {:noreply, journey |> settle(socket) |> focus_on_change(before)}

  defp after_continue({:stay, socket}, _journey, _before), do: {:noreply, socket}

  # `reason` is a semantic atom from the facts; rendering it to copy is this
  # layer's job, and the booking page is multi-locale.
  defp after_continue({:error, reason, socket}, _journey, _before),
    do: {:noreply, put_flash(socket, :error, BookingErrorMessage.message(reason))}

  defp run_back(moment, socket) do
    facts = Journey.facts()

    moment
    |> Progress.required(socket.assigns, facts)
    |> Enum.reduce_while({:leave, socket}, fn key, {:leave, acc} ->
      case Map.fetch!(facts, key).back(acc) do
        {:leave, acc} -> {:cont, {:leave, acc}}
        {:stay, acc} -> {:halt, {:stay, acc}}
      end
    end)
  end
end
