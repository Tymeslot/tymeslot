defmodule Tymeslot.Security.AccountLockout.TableOwner do
  @moduledoc """
  Owns the `:account_lockout_table` ETS table for `Tymeslot.Security.AccountLockout`
  and serialises failed-attempt writes so concurrent callers can't lose updates.

  Because ETS tables are tied to the lifetime of their owning process, keeping
  ownership here — rather than in the caller — ensures the table survives any
  individual caller crashing and being restarted on the same BEAM. The table is
  lost only when this process exits (i.e., on BEAM shutdown or a full application
  restart). It does NOT persist across deploys or node restarts.

  Reads go straight to ETS (atomic per row). Writes funnel through this
  GenServer, which eliminates the read-modify-write race that a `:public` table
  alone cannot prevent.
  """

  use GenServer

  @table :account_lockout_table
  @retention_seconds 86_400

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Atomically appends a failed attempt timestamp for `identifier` and returns
  the updated attempt count (within the 24h retention window).
  """
  @spec record_attempt(String.t()) :: pos_integer()
  def record_attempt(identifier) do
    GenServer.call(__MODULE__, {:record_attempt, identifier})
  end

  @impl GenServer
  def init(_state) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:record_attempt, identifier}, _from, state) do
    now = System.system_time(:second)

    updated =
      case :ets.lookup(@table, identifier) do
        [] ->
          [now]

        [{^identifier, attempts}] ->
          recent = Enum.filter(attempts, fn ts -> now - ts < @retention_seconds end)
          [now | recent]
      end

    :ets.insert(@table, {identifier, updated})
    {:reply, length(updated), state}
  end
end
