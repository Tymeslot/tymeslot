defmodule TymeslotWeb.Dashboard.Calendar.ViewportTest do
  @moduledoc """
  The server's first guess at whether the calendar is on a phone: the
  browser's own answer when the socket sends one, otherwise the user agent.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias TymeslotWeb.Dashboard.Calendar.Viewport

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
  @android_phone "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
  @android_tablet "Mozilla/5.0 (Linux; Android 15; Pixel Tablet) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  test "the browser's own answer wins over the user agent" do
    assert Viewport.from_connect(%{"viewport" => "phone"}, @desktop) == :phone
    assert Viewport.from_connect(%{"viewport" => "wide"}, @iphone) == :wide
  end

  test "without an answer, a phone's user agent means a phone" do
    assert Viewport.from_connect(nil, @iphone) == :phone
    assert Viewport.from_connect(%{}, @android_phone) == :phone
  end

  test "a tablet or a desktop user agent means wide" do
    assert Viewport.from_connect(nil, @android_tablet) == :wide
    assert Viewport.from_connect(%{}, @desktop) == :wide
  end

  test "an answer it does not know falls back to the user agent" do
    assert Viewport.from_connect(%{"viewport" => "tablet"}, @iphone) == :phone
    assert Viewport.from_connect(%{"viewport" => true}, @desktop) == :wide
  end

  test "no user agent at all means wide" do
    assert Viewport.from_connect(nil, nil) == :wide
    assert Viewport.from_connect(%{}, "unknown") == :wide
  end
end
