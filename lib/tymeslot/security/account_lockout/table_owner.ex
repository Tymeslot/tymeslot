defmodule Tymeslot.Security.AccountLockout.TableOwner do
  @moduledoc """
  Owns the `:account_lockout_table` ETS table for `Tymeslot.Security.AccountLockout`.

  Because ETS tables are tied to the lifetime of their owning process, keeping
  ownership here — rather than in the caller — ensures the table survives any
  individual caller crashing and being restarted on the same BEAM. The table is
  lost only when this process exits (i.e., on BEAM shutdown or a full application
  restart). It does NOT persist across deploys or node restarts.
  """

  use GenServer

  @table :account_lockout_table

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_state) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    {:ok, nil}
  end
end
