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

  import Tymeslot.ConfigTestHelpers

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

    # Force-disable legal agreements for Core E2E tests. A downstream overlay
    # can set enforce_legal_agreements: true, which overrides Core's test.exs
    # value when the suite runs under that overlay. The runtime override below
    # ensures Core E2E tests never see the legal gate.
    with_config(:tymeslot, :enforce_legal_agreements, false)

    # Browser requests are handled by a different OS process than the test,
    # so Mox expectations must be set globally.
    Mox.set_mox_global(tags)
    TestMocks.setup_all_mocks()

    # Signup and other flows read the verification module through Mox; without
    # a default stub the mock swallows every call. Matches ConnCase/LiveCase.
    DataCase.stub_verification_default()

    :ok
  end
end
