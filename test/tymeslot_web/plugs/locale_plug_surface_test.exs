defmodule TymeslotWeb.Plugs.LocalePlugSurfaceTest do
  # async: false — sets the global :admin_default_locale / :booking_default_locale
  # application env, which every other test's locale resolution also reads.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils
  @moduletag :plugs

  alias TymeslotWeb.Plugs.LocalePlug

  @surface_keys [:admin_default_locale, :booking_default_locale]

  setup do
    originals =
      Map.new(@surface_keys, fn key -> {key, Application.get_env(:tymeslot, key)} end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)
    end)

    # Distinct per surface so a plug that ignored `:surface` could not pass by
    # coincidence: the two fallbacks can never be confused for one another.
    Application.put_env(:tymeslot, :admin_default_locale, "de")
    Application.put_env(:tymeslot, :booking_default_locale, "fr")

    :ok
  end

  defp resolve(opts, req_headers \\ []) do
    Enum.reduce(req_headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> init_test_session(%{})
    |> Map.put(:params, %{})
    |> fetch_session()
    |> LocalePlug.call(opts)
  end

  describe "the surface option selects which fallback ends the chain" do
    test "surface: :admin falls back to the admin default" do
      assert resolve(surface: :admin).assigns.locale == "de"
    end

    test "surface: :booking falls back to the booking default" do
      assert resolve(surface: :booking).assigns.locale == "fr"
    end

    test "an unconfigured plug falls back to the booking default" do
      # The public surface is the safe way to be wrong: the plug is mounted on
      # public pipelines too, so an omitted option must not hand a visitor the
      # language the dashboard was configured for.
      assert resolve([]).assigns.locale == "fr"
    end
  end

  describe "the fallback never outranks a detected locale" do
    test "a supported Accept-Language wins over the admin fallback" do
      conn = resolve([surface: :admin], [{"accept-language", "fr"}])

      assert conn.assigns.locale == "fr"
    end

    test "a supported Accept-Language wins over the booking fallback" do
      conn = resolve([surface: :booking], [{"accept-language", "de"}])

      assert conn.assigns.locale == "de"
    end

    test "an explicit locale param wins over the surface fallback" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> Map.put(:params, %{"locale" => "it"})
        |> fetch_session()
        |> LocalePlug.call(surface: :admin)

      assert conn.assigns.locale == "it"
    end

    test "an Accept-Language naming nothing supported reaches the surface fallback" do
      conn = resolve([surface: :admin], [{"accept-language", "es,nl;q=0.8"}])

      assert conn.assigns.locale == "de"
    end
  end
end
