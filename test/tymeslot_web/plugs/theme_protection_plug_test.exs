defmodule TymeslotWeb.Plugs.ThemeProtectionPlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs

  alias TymeslotWeb.Plugs.ThemeProtectionPlug

  defmodule PassPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts), do: assign(conn, :pass_plug_called, true)
  end

  defmodule HaltPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end

  defmodule CrashPlug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(_conn, _opts), do: raise("boom")
  end

  defmodule OptsPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts), do: assign(conn, :received_opts, opts)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:tymeslot, :extra_theme_protection_plugs)
    end)
  end

  describe "init/1" do
    test "passes options through unchanged" do
      assert ThemeProtectionPlug.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    test "passes conn through when no plugs configured", %{conn: conn} do
      Application.delete_env(:tymeslot, :extra_theme_protection_plugs)

      result = ThemeProtectionPlug.call(conn, [])

      refute result.halted
    end

    test "executes a passing plug", %{conn: conn} do
      Application.put_env(:tymeslot, :extra_theme_protection_plugs, [PassPlug])

      result = ThemeProtectionPlug.call(conn, [])

      refute result.halted
      assert result.assigns[:pass_plug_called] == true
    end

    test "halts when a plug halts", %{conn: conn} do
      Application.put_env(:tymeslot, :extra_theme_protection_plugs, [HaltPlug])

      result = ThemeProtectionPlug.call(conn, [])

      assert result.halted
      assert result.status == 403
    end

    test "does not call subsequent plugs after a halt", %{conn: conn} do
      Application.put_env(:tymeslot, :extra_theme_protection_plugs, [HaltPlug, PassPlug])

      result = ThemeProtectionPlug.call(conn, [])

      assert result.halted
      refute Map.has_key?(result.assigns, :pass_plug_called)
    end

    test "supports {module, opts} tuple format", %{conn: conn} do
      Application.put_env(:tymeslot, :extra_theme_protection_plugs, [
        {OptsPlug, [custom: :value]}
      ])

      result = ThemeProtectionPlug.call(conn, [])

      refute result.halted
      assert result.assigns[:received_opts] == [custom: :value]
    end

    test "reraises exceptions from crashing plugs", %{conn: conn} do
      Application.put_env(:tymeslot, :extra_theme_protection_plugs, [CrashPlug])

      assert_raise RuntimeError, "boom", fn ->
        ThemeProtectionPlug.call(conn, [])
      end
    end
  end
end
