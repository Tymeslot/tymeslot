defmodule TymeslotWeb.EmbedJsTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  @embed_js_path Path.expand("../../assets/js/embed.js", __DIR__)

  test "username is URL encoded in booking iframe URL" do
    contents = File.read!(@embed_js_path)

    assert contents =~ "encodeURIComponent(username)"
  end

  test "body overflow is restored after closing modal" do
    contents = File.read!(@embed_js_path)

    assert contents =~ "previousBodyOverflow"
    assert contents =~ "document.body.style.overflow = modal.previousBodyOverflow"
  end

  test "resize listener is global" do
    contents = File.read!(@embed_js_path)

    assert contents =~ "window.addEventListener('message'"
  end
end
