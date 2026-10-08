defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous do
  @moduledoc """
  Every moment the booking has reached, on one page, in journey order: the
  moments done stay where they are and stay usable, the moment still to
  complete is last, and the next opens below it by itself once its turn
  comes (`Navigators.Reveal`). A moment collecting nothing (a masthead) is
  there once reached. The moment that just opened takes the focus through
  its `Journey.Components.moment_heading/1`.

  There is no page to go back to: `back/2` only steps back inside the
  current moment (the questions wizard), and `go_to/3` changes nothing, since
  a done moment is on the page above; `Blocks.SummaryBar` links to it.

  The moments sit in `<div class="journey journey--continuous">`.
  """

  @behaviour TymeslotWeb.Themes.Shared.Journey.Navigator

  alias TymeslotWeb.Themes.Shared.Journey.Navigator
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal

  @impl Navigator
  def entry(journey, live_action, _assigns), do: Reveal.entry(journey, live_action)

  @impl Navigator
  def visible(journey, assigns), do: Reveal.visible(journey, assigns)

  @impl Navigator
  def continue(journey, socket), do: Reveal.continue(journey, socket)

  @impl Navigator
  def back(journey, socket), do: Reveal.back(journey, socket, &{:noreply, &1})

  @impl Navigator
  def go_to(_journey, socket, _step), do: {:noreply, socket}

  @impl Navigator
  def settle(journey, socket), do: Reveal.settle(journey, socket)

  @impl Navigator
  def frame, do: {"div", [class: "journey journey--continuous"]}
end
