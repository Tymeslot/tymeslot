defmodule Tymeslot.Test.HtmlFailureFormatterTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :unit

  alias ExUnit.AssertionError
  alias Tymeslot.Test.HtmlFailureFormatter

  @padding String.duplicate("<path d=\"M0 0h24v24H0z\"/>", 200)

  @page """
  <!DOCTYPE html>
  <html>
    <head><title>Book a meeting</title><script>window.secretBundle = 1;</script></head>
    <body>
      <nav>Site navigation</nav>
      <svg>#{@padding}</svg>
      <main>
        <h1>Booking confirmed</h1>
        <a href="/meetings/42" class="btn-primary">View meeting</a>
      </main>
    </body>
  </html>
  """

  defp failure(fun) do
    fun.()
    flunk("expected the assertion to fail")
  rescue
    error in AssertionError -> HtmlFailureFormatter.shorten(error)
  end

  describe "a failed assert html =~ text" do
    test "replaces the page with the visible text of <main> and the nearest partial match" do
      error = failure(fn -> assert @page =~ "Booking cancelled" end)

      assert error.left == "<#{byte_size(@page)} bytes of rendered output, excerpt above>"
      assert error.right == "Booking cancelled"
      assert error.message =~ "Visible text of <main>:\nBooking confirmed View meeting"
      assert error.message =~ ~s[Nearest partial match ("Booking c" of "Booking cancelled")]
      refute error.message =~ "secretBundle"
      refute error.message =~ "Site navigation"
      assert byte_size(error.message) < 2_000
    end

    test "says so when no prefix of the expected text occurs" do
      error = failure(fn -> assert @page =~ "Zebra" end)

      assert error.message =~ "Visible text of <main>"
      assert error.message =~ "No partial match found."
    end
  end

  describe "a failed assert html =~ markup" do
    test "shows the raw HTML around the nearest partial match instead of visible text" do
      error = failure(fn -> assert @page =~ ~s(<a href="/meetings/43") end)

      assert error.message =~ ~s(class="btn-primary">View meeting</a>)
      refute error.message =~ "Visible text"
    end

    test "anchors a regex on its literal prefix" do
      error = failure(fn -> assert @page =~ ~r/class="btn-secondary"/ end)

      assert error.message =~ ~s[Nearest partial match ("class=\\"btn-"]
      assert error.message =~ ~s(<a href="/meetings/42")
    end
  end

  describe "a failed refute html =~" do
    test "centres the excerpt on the unwanted match" do
      error = failure(fn -> refute @page =~ "View meeting" end)

      assert error.message =~ "Refute with =~ failed"
      assert error.message =~ ~s(Unwanted match at byte )
      assert error.message =~ ~s(class="btn-primary">View meeting</a>)
      refute error.message =~ "secretBundle"
    end
  end

  describe "errors it leaves alone" do
    test "a short left-hand side" do
      error = failure(fn -> assert "<p>short</p>" =~ "long" end)

      assert error.left == "<p>short</p>"
      assert error.message == "Assertion with =~ failed"
    end

    test "an assertion with another operator" do
      error = failure(fn -> assert @page == "other" end)

      assert error.left == @page
    end
  end
end
