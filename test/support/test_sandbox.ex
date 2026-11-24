defmodule Tymeslot.TestSandbox do
  @moduledoc """
  What a browser test's requests and LiveViews are allowed to share with the
  test: its database connection and its Mox expectations and stubs.

  `Fluffy.Sandbox` and `Phoenix.Ecto.SQL.Sandbox` call `allow/3` for each
  process that serves the test's browser (`config :fluffy, Fluffy.Sandbox`),
  so the browser tests can run async. Mox's global mode would hand every
  test's expectations to every process on the node instead.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Allows `child` to use `owner`'s connection to `repo` and every mock `owner`
  can see.
  """
  @spec allow(Ecto.Repo.t(), pid(), pid()) :: :ok
  def allow(repo, owner, child) do
    Sandbox.allow(repo, owner, child, unallow_existing: true)

    # A request can outlive its test (the browser closes after the test
    # process exits). In Mox 1.3.2, `Mox.allow/3` with a dead owner loops
    # forever (fixed upstream in dashbitco/mox#181), so skip the mocks then.
    for mock <- mocks(), Process.alive?(owner), do: Mox.allow(mock, owner, child)
    :ok
  end

  # Every module `Mox.defmock/2` defined (test/support/mocks/defmocks.ex),
  # found once. Only modules named `*Mock` are loaded to check: loading all of
  # the app's modules from the first requests of an async run stalls the code
  # server long enough to time out their page loads.
  defp mocks do
    with nil <- :persistent_term.get(__MODULE__, nil) do
      mocks =
        for module <- Application.spec(:tymeslot, :modules),
            String.ends_with?(Atom.to_string(module), "Mock"),
            Code.ensure_loaded?(module),
            function_exported?(module, :__mock_for__, 0),
            do: module

      :persistent_term.put(__MODULE__, mocks)
      mocks
    end
  end
end
