defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.Paged do
  @moduledoc """
  The classic navigator: one moment on screen at a time, with Next and Back.

  Next (`continue/2`) asks each fact of the current moment that this booking
  needs whether the booker may leave (`Fact.continue/1`), in the moment's
  order: an error is flashed (`BookingErrorMessage`), a `:stay` keeps the
  moment (the questions wizard moving between questions), and when every one
  is done the next moment with a needed fact is shown. Back (`back/2`) asks
  the current moment's facts first (`Fact.back/1`), then shows the previous
  moment with a needed fact if every one of them may be revisited
  (`Fact.revisitable?/1`: the overview only for a booker who came through
  it); otherwise the booker stays. The step indicator (`go_to/3`) numbers
  the moments with a needed fact from 1, gives every outcome the number
  after them, and only moves back to a moment that may be revisited, as Back
  does. On the payment wait (`:awaiting_payment`) it moves nowhere: that
  outcome's number would let it back to the booking form while the checkout
  is open, so only the payment webhook ends the wait.

  A moment none of whose facts this booking needs is skipped: the questions
  of a meeting type that has none. Moments are shown through
  `Journey.Runtime.transition_to/3`.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigator
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @behaviour Navigator

  @impl Navigator
  def entry(journey, live_action, _assigns) do
    [first | _rest] = journey.moments

    case live_action do
      :overview -> first.key
      :schedule -> first_collecting(journey, :slot)
      :booking -> first_collecting(journey, :attendee)
      :confirmation -> :confirmation
      _other -> first.key
    end
  end

  @impl Navigator
  def visible(journey, assigns) do
    state = assigns[:current_state]

    case Journey.moment(journey, state) do
      nil ->
        if Map.has_key?(journey.outcomes, state),
          do: [],
          else: [{hd(journey.moments), :current}]

      moment ->
        [{moment, :current}]
    end
  end

  @impl Navigator
  def continue(journey, socket) do
    case Journey.moment(journey, socket.assigns[:current_state]) do
      nil -> {:noreply, socket}
      moment -> leave_forward(journey, moment, socket)
    end
  end

  @impl Navigator
  def back(journey, socket) do
    case Journey.moment(journey, socket.assigns[:current_state]) do
      nil -> {:noreply, socket}
      moment -> leave_backward(journey, moment, socket)
    end
  end

  # While a checkout is open only the payment webhook moves the booker on
  # (`:paid` to the confirmation, `:expired` to the booking form): a moment
  # behind the wait would take a second submit for the slot it holds.
  @impl Navigator
  def go_to(_journey, %{assigns: %{current_state: :awaiting_payment}} = socket, _step),
    do: {:noreply, socket}

  # `step` is the page's string; one that is not a number moves nothing.
  def go_to(journey, socket, step) do
    numbered = numbered_moments(journey, socket.assigns)
    current = number_of(journey, numbered, socket.assigns[:current_state])

    with {number, _rest} <- Integer.parse(step),
         {target, ^number} <- List.keyfind(numbered, number, 1),
         true <- is_integer(current) and number < current,
         true <- revisitable?(Journey.moment(journey, target), socket.assigns) do
      {:noreply, Runtime.transition_to(socket, target, %{})}
    else
      _no_move -> {:noreply, socket}
    end
  end

  defp first_collecting(journey, fact), do: Enum.find(journey.moments, &(fact in &1.collects)).key

  # `reason` is a semantic atom from the facts; rendering it to copy is this
  # layer's job, and the booking page is multi-locale.
  defp leave_forward(journey, moment, socket) do
    case continue_facts(Journey.required_facts(moment, socket.assigns), socket) do
      {:done, socket} ->
        {:noreply, show_next(journey, moment, socket)}

      {:stay, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, BookingErrorMessage.message(reason))}
    end
  end

  defp continue_facts(facts, socket) do
    Enum.reduce_while(facts, {:done, socket}, fn fact, {:done, socket} ->
      case fact.continue(socket) do
        {:done, socket} -> {:cont, {:done, socket}}
        {:stay, socket} -> {:halt, {:stay, socket}}
        {:error, reason} -> {:halt, {:error, reason, socket}}
      end
    end)
  end

  defp show_next(journey, moment, socket) do
    next =
      journey.moments
      |> Enum.drop_while(&(&1.key != moment.key))
      |> Enum.drop(1)
      |> Enum.find(&needed?(&1, socket.assigns))

    if next, do: Runtime.transition_to(socket, next.key, %{}), else: socket
  end

  defp leave_backward(journey, moment, socket) do
    case back_facts(Journey.required_facts(moment, socket.assigns), socket) do
      {:stay, socket} -> {:noreply, socket}
      {:leave, socket} -> {:noreply, show_previous(journey, moment, socket)}
    end
  end

  defp back_facts(facts, socket) do
    Enum.reduce_while(facts, {:leave, socket}, fn fact, {:leave, socket} ->
      case fact.back(socket) do
        {:leave, socket} -> {:cont, {:leave, socket}}
        {:stay, socket} -> {:halt, {:stay, socket}}
      end
    end)
  end

  defp show_previous(journey, moment, socket) do
    previous =
      journey.moments
      |> Enum.take_while(&(&1.key != moment.key))
      |> Enum.reverse()
      |> Enum.find(&needed?(&1, socket.assigns))

    if previous && revisitable?(previous, socket.assigns),
      do: Runtime.transition_to(socket, previous.key, %{}),
      else: socket
  end

  defp revisitable?(moment, assigns) do
    moment
    |> Journey.required_facts(assigns)
    |> Enum.all?(& &1.revisitable?(assigns))
  end

  defp needed?(moment, assigns), do: Journey.required_facts(moment, assigns) != []

  defp numbered_moments(journey, assigns) do
    journey.moments
    |> Enum.filter(&needed?(&1, assigns))
    |> Enum.map(& &1.key)
    |> Enum.with_index(1)
  end

  # A moment's number, or for an outcome the one after the last moment's.
  defp number_of(journey, numbered, state) do
    case List.keyfind(numbered, state, 0) do
      {_key, number} -> number
      nil -> if Map.has_key?(journey.outcomes, state), do: length(numbered) + 1
    end
  end
end
