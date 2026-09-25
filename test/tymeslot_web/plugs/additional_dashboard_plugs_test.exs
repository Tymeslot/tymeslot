defmodule TymeslotWeb.Plugs.AdditionalDashboardPlugsTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :security
  @moduletag :dashboard
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias TymeslotWeb.Plugs.AdditionalDashboardPlugs

  # Two stand-ins for whatever an overlay configures: one that lets the request
  # through, one that halts it the way a gate would.
  defmodule PassthroughPlug do
    @moduledoc false
    import Plug.Conn

    @spec init(Keyword.t()) :: Keyword.t()
    def init(opts), do: opts

    @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
    def call(conn, _opts), do: assign(conn, :passed_through, true)
  end

  defmodule HaltingPlug do
    @moduledoc false
    import Plug.Conn

    @spec init(Keyword.t()) :: Keyword.t()
    def init(opts), do: opts

    @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
    def call(conn, _opts) do
      conn |> assign(:halted_by, :halting_plug) |> halt()
    end
  end

  defmodule OptsPlug do
    @moduledoc false
    import Plug.Conn

    @spec init(Keyword.t()) :: Keyword.t()
    def init(opts), do: Keyword.put(opts, :initialised, true)

    @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
    def call(conn, opts), do: assign(conn, :received_opts, opts)
  end

  describe "with no configuration" do
    test "is inert, which is what a standalone Core deployment runs", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [])

      result = AdditionalDashboardPlugs.call(conn, [])

      refute result.halted
      assert result == conn
    end
  end

  describe "running configured plugs" do
    test "runs a configured plug", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [PassthroughPlug])

      assert AdditionalDashboardPlugs.call(conn, []).assigns[:passed_through]
    end

    test "halts the request when a configured plug halts", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [HaltingPlug])

      result = AdditionalDashboardPlugs.call(conn, [])

      assert result.halted
      assert result.assigns[:halted_by] == :halting_plug
    end

    test "stops at the first halt rather than running later plugs", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [HaltingPlug, PassthroughPlug])

      result = AdditionalDashboardPlugs.call(conn, [])

      assert result.halted
      refute result.assigns[:passed_through]
    end

    test "runs plugs in order when none halt", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [PassthroughPlug, OptsPlug])

      result = AdditionalDashboardPlugs.call(conn, [])

      refute result.halted
      assert result.assigns[:passed_through]
      assert result.assigns[:received_opts][:initialised]
    end

    test "passes a {module, opts} entry through the module's own init/1", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [{OptsPlug, [from_config: :yes]}])

      opts = AdditionalDashboardPlugs.call(conn, []).assigns[:received_opts]

      assert opts[:from_config] == :yes
      assert opts[:initialised]
    end
  end

  describe "malformed configuration" do
    test "wraps a single plug given outside a list", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: PassthroughPlug)

      assert AdditionalDashboardPlugs.call(conn, []).assigns[:passed_through]
    end

    # These plugs are deployment gates. A configuration they cannot be run
    # from used to be skipped, which let every request through the gate.
    test "raises on a value that is neither a list nor a plug", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: %{not: "a plug"})

      assert_raise ArgumentError, ~r/:dashboard_additional_plugs/, fn ->
        AdditionalDashboardPlugs.call(conn, [])
      end
    end

    test "raises on an entry that is neither a module nor a {module, opts} tuple", %{conn: conn} do
      setup_config(:tymeslot, dashboard_additional_plugs: [PassthroughPlug, "MyApp.Plugs.Typo"])

      assert_raise ArgumentError, ~r/unrecognised :dashboard_additional_plugs entry/, fn ->
        AdditionalDashboardPlugs.call(conn, [])
      end
    end

    test "raises before running any plug, so a gate is never half-applied", %{conn: conn} do
      setup_config(:tymeslot,
        dashboard_additional_plugs: [PassthroughPlug, {HaltingPlug, [], :extra}]
      )

      assert_raise ArgumentError, fn -> AdditionalDashboardPlugs.call(conn, []) end
    end
  end

  describe "validate_config!/0 (run at boot)" do
    test "accepts module plugs, bare or with options" do
      setup_config(:tymeslot, dashboard_additional_plugs: [PassthroughPlug, {OptsPlug, [a: 1]}])

      assert :ok = AdditionalDashboardPlugs.validate_config!()
    end

    test "rejects a well-formed entry naming a module that does not exist" do
      setup_config(:tymeslot, dashboard_additional_plugs: [MyApp.Plugs.Mispelt])

      assert_raise ArgumentError, ~r/MyApp.Plugs.Mispelt, which is not a module plug/, fn ->
        AdditionalDashboardPlugs.validate_config!()
      end
    end
  end
end
