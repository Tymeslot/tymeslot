defmodule TymeslotWeb.Dev.EmbedTestControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :dev_support
  @moduletag :security
  @moduletag :controllers

  alias Phoenix.Controller
  alias TymeslotWeb.Dev.EmbedTestController
  alias TymeslotWeb.Endpoint

  # The route is only compiled in when `config :tymeslot, :dev_routes` is true,
  # which only `config/dev.exs` sets, so the page is unreachable through the
  # router here. Calling the controller as a plug runs everything the route
  # would bar the pipeline itself: the action, the view lookup, and the render.
  # `put_format/2` stands in for the `:browser` pipeline's `plug :accepts`.
  defp request(params) do
    :get
    |> build_conn("/dev/embed-test", params)
    |> Controller.put_format("html")
    |> assign(:csp_nonce, "test-nonce-123")
    |> EmbedTestController.call(:index)
  end

  describe "index/2" do
    test "escapes a username carrying markup instead of emitting it raw" do
      conn = request(%{"username" => "\"><script>alert(1)</script>"})
      body = html_response(conn, 200)

      refute body =~ "<script>alert(1)"
      assert body =~ "&lt;script&gt;alert(1)"
      # The quote is escaped too, so the value cannot close its own attribute.
      refute body =~ ~s(value=""><script)
    end

    test "defaults the username and renders the four embed scenarios" do
      body = html_response(request(%{}), 200)

      assert body =~ ~s(value="demo")
      assert body =~ ~s(id="embed-full")
      assert body =~ ~s(id="embed-constrained")
      assert body =~ ~s(id="embed-small")
      assert body =~ ~s(id="popup-btn")
    end

    test "loads embed.js from the endpoint and keeps the script CSP-compliant" do
      body = html_response(request(%{}), 200)

      assert body =~ ~s(src="#{Endpoint.url()}/embed.js")
      assert body =~ ~s(nonce="test-nonce-123")
      # The behaviour is bound in JavaScript, never through an inline handler
      # attribute, which the dev CSP would block.
      assert body =~ "addEventListener('click', reload)"
      refute body =~ "onclick="
    end

    test "leaves the inline stylesheet and script bodies uninterpolated" do
      body = html_response(request(%{}), 200)

      assert body =~ "grid-template-columns: 1fr 1fr;"
      assert body =~ "TymeslotBooking.embed('#' + id, user, opts);"
    end

    test "renders a standalone document with no app chrome" do
      body = html_response(request(%{}), 200)

      assert String.starts_with?(body, "<!DOCTYPE html>")
      refute body =~ "phx-main"
    end
  end
end
