defmodule TymeslotWeb.BrowserCase do
  @moduledoc """
  Test case for Fluffy-based E2E browser tests.

  Uses `Playwright.Test` with project-specific setup: sandbox sharing, mocks,
  stateful component reset (sync modules only), and factory imports. A
  browser test runs `async: true` unless it changes node-wide state.

  Each test gets a Playwright browser session as `%{session: session}`.

  ## Usage

      use TymeslotWeb.BrowserCase
      @moduletag :e2e

      test "user can log in", %{session: session} do
        session
        |> visit("/auth/login")
        |> fill(by_css("#email"), "user@example.com")
        ...
      end
  """

  use ExUnit.CaseTemplate

  alias Tymeslot.DataCase
  alias Tymeslot.TestMocks

  using opts do
    quote do
      use Playwright.Test, unquote(opts)
      use Fluffy.Assert

      import Fluffy
      import Fluffy.Locator
      import Fluffy.Playwright, only: [hover: 2, inner_text: 2, set_viewport_size: 2]
      import Tymeslot.Factory
      import TymeslotWeb.E2EHelpers

      # A domain sweep (`--only auth`) would otherwise run every browser test
      # it reaches, failing them where the endpoint is not serving; see
      # `Tymeslot.Test.SuiteConfig.unless_included/1`.
      @moduletag skip: Tymeslot.Test.SuiteConfig.unless_included(:e2e)

      setup do
        %{session: start_session(:playwright)}
      end
    end
  end

  setup tags do
    # Fluffy passes the sandbox metadata to the browser session (via the
    # ecto_repos config), so browser requests and LiveViews share this owner's
    # connection and, through `Tymeslot.TestSandbox`, its mocks. The legal gate
    # is switched off for the run in test_helper.exs.
    DataCase.setup_sandbox(tags)
    DataCase.reset_stateful_components(tags)
    TestMocks.setup_all_mocks()

    :ok
  end
end
