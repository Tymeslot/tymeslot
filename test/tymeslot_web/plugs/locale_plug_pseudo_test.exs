defmodule TymeslotWeb.Plugs.LocalePlugPseudoTest do
  # async: false — toggles the global :pseudo_locale_enabled application env.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  alias TymeslotWeb.Plugs.LocalePlug

  setup do
    original = Application.get_env(:tymeslot, :pseudo_locale_enabled)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :pseudo_locale_enabled)
      else
        Application.put_env(:tymeslot, :pseudo_locale_enabled, original)
      end

      Gettext.put_locale(TymeslotWeb.Gettext, "en")
    end)

    :ok
  end

  defp call_with_locale_param(locale) do
    build_conn()
    |> init_test_session(%{})
    |> Map.put(:params, %{"locale" => locale})
    |> fetch_session()
    |> LocalePlug.call([])
  end

  describe "pseudo locale" do
    test "?locale=pseudo is honoured when pseudo-localisation is enabled" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)

      conn = call_with_locale_param("pseudo")

      assert conn.assigns.locale == "pseudo"
      assert get_session(conn, :locale) == "pseudo"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "pseudo"
    end

    test "?locale=pseudo is rejected when pseudo-localisation is disabled" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, false)

      conn = call_with_locale_param("pseudo")

      assert conn.assigns.locale == "en"
    end
  end
end
