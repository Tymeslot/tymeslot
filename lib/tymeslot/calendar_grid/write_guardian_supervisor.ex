defmodule Tymeslot.CalendarGrid.WriteGuardianSupervisor do
  @moduledoc """
  Supervises what the calendar grid's write guardians need: the Registry
  each registers in under its LiveView's pid, the one each registers in
  under its user's id, and the DynamicSupervisor each runs under (see
  `Tymeslot.CalendarGrid.WriteGuardian`).
  """

  use Supervisor

  alias Tymeslot.CalendarGrid.WriteGuardian

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init(
      [
        Supervisor.child_spec({Registry, keys: :unique, name: WriteGuardian.registry()},
          id: WriteGuardian.registry()
        ),
        Supervisor.child_spec(
          {Registry, keys: :duplicate, name: WriteGuardian.user_registry()},
          id: WriteGuardian.user_registry()
        ),
        {DynamicSupervisor, name: WriteGuardian.supervisor(), strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end
end
