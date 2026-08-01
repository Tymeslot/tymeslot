defmodule TymeslotWeb.AnalyticsScriptsTest do
  # async: false — mutates the global :analytics_providers app env.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Layouts

  @moduletag :components

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

  defp render_scripts(assigns \\ %{}) do
    (&Layouts.analytics_scripts/1)
    |> render_component(assigns)
    |> String.trim()
  end

  defp configure_umami do
    Application.put_env(:tymeslot, :analytics_providers, [
      %{
        provider: :umami,
        script_url: "https://analytics.example.com/script.js",
        website_id: "abc-123"
      }
    ])
  end

  describe "analytics_scripts/1" do
    test "defers the tracker to an idle callback after load rather than shipping it inline" do
      configure_umami()

      html = render_scripts()

      # The tracker must not be a src'd tag the parser schedules itself: a
      # `defer`red tracker runs in the DOMContentLoaded pileup and forces a
      # synchronous full-document layout inside a script task.
      refute html =~ ~s(<script defer src=)
      assert html =~ "requestIdleCallback"
      assert html =~ ~s(addEventListener("load")
    end

    test "carries the script URL and website id as data attributes, not in the script body" do
      configure_umami()

      html = render_scripts()

      assert html =~ ~s(data-analytics-src="https://analytics.example.com/script.js")
      assert html =~ ~s(data-analytics-website-id="abc-123")
      assert html =~ "document.currentScript"
    end

    test "announces arrival so buffered events can be flushed" do
      configure_umami()

      assert render_scripts() =~ "tymeslot:analytics-ready"
    end

    test "applies the CSP nonce to the inline loader" do
      configure_umami()

      assert render_scripts(%{nonce: "test-nonce"}) =~ ~s(nonce="test-nonce")
    end

    test "renders nothing when analytics is unconfigured" do
      Application.put_env(:tymeslot, :analytics_providers, [])
      assert render_scripts() == ""

      Application.delete_env(:tymeslot, :analytics_providers)
      assert render_scripts() == ""
    end

    test "renders nothing for a provider missing its website id" do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{provider: :umami, script_url: "https://analytics.example.com/script.js", website_id: ""}
      ])

      assert render_scripts() == ""
    end
  end
end
