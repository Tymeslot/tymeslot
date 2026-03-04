defmodule TymeslotWeb.BrowserCase do
  @moduledoc """
  Test case for Wallaby-based E2E browser tests.

  Wraps `Wallaby.Feature` with project-specific setup: sandbox sharing,
  global Mox configuration, stateful component reset, and factory imports.

  Tests use the `feature` macro (from `Wallaby.Feature`) instead of `test`.
  The macro manages browser session lifecycle and injects `%{session: session}`.

  ## Usage

      use TymeslotWeb.BrowserCase
      @moduletag :e2e

      feature "user can log in", %{session: session} do
        session
        |> visit("/auth/login")
        |> fill_in(Query.text_field("email"), with: "user@example.com")
        ...
      end
  """

  use ExUnit.CaseTemplate

  alias Tymeslot.DataCase
  alias Tymeslot.TestMocks

  using do
    quote do
      use Wallaby.Feature

      import Tymeslot.Factory
      import TymeslotWeb.E2EHelpers
      import Wallaby.Query
    end
  end

  setup tags do
    # Do NOT call DataCase.setup_sandbox here — Wallaby.Feature handles sandbox
    # checkout itself (via otp_app + ecto_repos config) and passes the metadata
    # to the browser session. A double checkout would split the sandbox: factory
    # data would land in one connection while Phoenix.Ecto.SQL.Sandbox routes the
    # server to a different one, making inserted rows invisible to browser requests.
    DataCase.reset_stateful_components()

    # Browser requests are handled by a different OS process than the test,
    # so Mox expectations must be set globally.
    Mox.set_mox_global(tags)
    TestMocks.setup_all_mocks()

    :ok
  end
end
