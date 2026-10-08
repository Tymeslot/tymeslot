defmodule TymeslotWeb.Themes.Shared.Journey.Navigator do
  @moduledoc """
  How a journey's moments meet the screen: which moment a route opens on,
  which moments are visible, and what "next", "back" and a click on the step
  indicator do.

  `:current_state` stays the assign naming what is on screen: the current
  moment's key, or an outcome (`:confirmation`, `:awaiting_payment`).

    * `entry/3`: the moment (or outcome) a route opens on. `:overview` is the
      first moment, `:schedule` the first collecting `:slot`, `:booking` the
      first collecting `:attendee`, `:confirmation` the outcome, anything
      else the first moment;
    * `visible/2`: the moments on screen, each `:current`, `:done` or
      `:open`; empty while an outcome is shown;
    * `continue/2` and `back/2`: the canonical `next_step` and `back_step`
      from the current moment;
    * `go_to/3`: the step indicator's `navigate_to_step`, with the step
      number as the page sent it.

  `Navigators.Paged` is the classic one: one moment per screen.
  """

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment

  @typedoc "How a visible moment stands."
  @type moment_state :: :current | :done | :open

  @doc "The moment or outcome the route opens on."
  @callback entry(Journey.t(), live_action :: atom(), assigns :: map()) :: atom()

  @doc "The moments on screen, in order."
  @callback visible(Journey.t(), assigns :: map()) :: [{Moment.t(), moment_state()}]

  @doc "The booker's `next_step` from the current moment."
  @callback continue(Journey.t(), Socket.t()) :: {:noreply, Socket.t()}

  @doc "The booker's `back_step` from the current moment."
  @callback back(Journey.t(), Socket.t()) :: {:noreply, Socket.t()}

  @doc "A click on the step indicator's `step`."
  @callback go_to(Journey.t(), Socket.t(), step :: String.t()) :: {:noreply, Socket.t()}

  @doc """
  Reveals what the booking reaches now: for a navigator that shows several
  moments and moves on by itself, opens each newly reached moment
  (`Journey.Runtime.open_moment/3`) and sets `:current_state` to the moment
  still to complete. `Journey.Runtime.settle/1` calls it after a moment is
  entered and after every fact or ambient event. Optional: a navigator that
  moves only on Next and Back (`Navigators.Paged`) has none.
  """
  @callback settle(Journey.t(), Socket.t()) :: Socket.t()

  @doc """
  The element the visible moments sit in, as a tag and its attributes
  (`Journey.Components.frame/1` renders it). Optional: without it the moment
  is rendered bare, as `Navigators.Paged`'s one moment is.
  """
  @callback frame() :: {String.t(), keyword()}

  @optional_callbacks settle: 2, frame: 0
end
