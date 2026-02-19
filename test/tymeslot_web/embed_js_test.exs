defmodule TymeslotWeb.EmbedJsTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  @embed_js_source Path.expand("../../assets/js/embed.js", __DIR__)

  test "embed.js is declared as a publicly served static path" do
    # Ensures embed.js will be served by Plug.Static when assets are deployed.
    # If this is removed from static_paths, the widget will 404 for all embedders.
    assert "embed.js" in TymeslotWeb.static_paths()
  end

  test "embed.js source file exists at the expected asset location" do
    assert File.exists?(@embed_js_source),
           "embed.js not found at #{@embed_js_source} — behavioral tests in embed.test.js depend on this file"
  end
end
