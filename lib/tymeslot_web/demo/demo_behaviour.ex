defmodule TymeslotWeb.DemoBehaviour do
  @moduledoc """
  Behaviour for simple demo state machines used by homepage and other UI demos.
  """

  @callback initial_state() :: map()
  @callback handle_demo_event(atom(), any(), map()) :: map()
end
