defmodule TymeslotWeb.BrowserCase do
  @moduledoc """
  Test case for Fluffy-based E2E browser tests.

  Uses `Playwright.Test` with project-specific setup: sandbox sharing,
  global Mox configuration, stateful component reset, and factory imports.

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

  import Tymeslot.ConfigTestHelpers

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
    # ecto_repos config), so browser requests share this owner's connection.
    DataCase.setup_sandbox(tags)
    DataCase.reset_stateful_components(tags)

    # Force-disable legal agreements for Core E2E tests. A downstream overlay
    # can set enforce_legal_agreements: true, which overrides Core's test.exs
    # value when the suite runs under that overlay. The runtime override below
    # ensures Core E2E tests never see the legal gate.
    with_config(:tymeslot, :enforce_legal_agreements, false)

    # Browser requests are handled by a different OS process than the test,
    # so Mox expectations must be set globally.
    Mox.set_mox_global(tags)
    TestMocks.setup_all_mocks()

    :ok
  end
end
