defmodule TymeslotWeb.AnalyticsPreconnectTest do
  # async: false — mutates the global :analytics_providers app env.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Layouts

  @moduletag :components
  @moduletag :analytics

  setup do
    original = Application.get_env(:tymeslot, :analytics_providers)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :analytics_providers)
        value -> Application.put_env(:tymeslot, :analytics_providers, value)
      end
    end)

    :ok
  end

  defp render do
    (&Layouts.analytics_preconnect/1)
    |> render_component(%{})
    |> String.trim()
  end

  describe "analytics_preconnect/1" do
    test "emits a preconnect hint for a configured external tracker origin" do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{
          provider: :umami,
          script_url: "https://analytics.example.com/script.js",
          website_id: "abc"
        }
      ])

      html = render()

      assert html =~ ~s(rel="preconnect")
      assert html =~ ~s(href="https://analytics.example.com")
      # Only the origin, never the full script path.
      refute html =~ "/script.js"
    end

    test "renders nothing when analytics is unconfigured" do
      Application.put_env(:tymeslot, :analytics_providers, [])
      assert render() == ""

      Application.delete_env(:tymeslot, :analytics_providers)
      assert render() == ""
    end

    test "skips same-origin (relative) script URLs, which need no preconnect" do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{provider: :umami, script_url: "/umami.js", website_id: "abc"}
      ])

      assert render() == ""
    end

    test "preserves a non-default port in the origin" do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{
          provider: :umami,
          script_url: "https://analytics.example.com:8443/s.js",
          website_id: "abc"
        }
      ])

      assert render() =~ ~s(href="https://analytics.example.com:8443")
    end

    test "de-duplicates repeated origins across providers" do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{provider: :umami, script_url: "https://a.example.com/one.js", website_id: "x"},
        %{provider: :umami, script_url: "https://a.example.com/two.js", website_id: "y"}
      ])

      occurrences =
        render()
        |> String.split(~s(href="https://a.example.com"))
        |> length()

      # One link → the split yields exactly two fragments.
      assert occurrences == 2
    end
  end
end
