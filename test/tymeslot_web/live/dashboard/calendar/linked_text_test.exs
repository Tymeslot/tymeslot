defmodule TymeslotWeb.Dashboard.Calendar.LinkedTextTest do
  @moduledoc """
  The web addresses in an event's place and notes become links: only http
  and https ones, escaped, opening in a new tab without handing the page
  over to the site.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Dashboard.Calendar.LinkedText

  describe "parts/1" do
    test "splits the text around each web address" do
      assert LinkedText.parts("Agenda: https://docs.example.com/a?b=1 and http://x.example") == [
               {:text, "Agenda: "},
               {:link, "https://docs.example.com/a?b=1"},
               {:text, " and "},
               {:link, "http://x.example"}
             ]
    end

    test "leaves the punctuation that ends a sentence out of the address" do
      assert LinkedText.parts("See https://example.com/page.") == [
               {:text, "See "},
               {:link, "https://example.com/page"},
               {:text, "."}
             ]

      assert LinkedText.parts("(https://example.com)") == [
               {:text, "("},
               {:link, "https://example.com"},
               {:text, ")"}
             ]
    end

    test "keeps a closing bracket the address opened itself" do
      assert LinkedText.parts("See https://en.wikipedia.org/wiki/Foo_(bar).") == [
               {:text, "See "},
               {:link, "https://en.wikipedia.org/wiki/Foo_(bar)"},
               {:text, "."}
             ]

      assert LinkedText.parts("(https://en.wikipedia.org/wiki/Foo_(bar))") == [
               {:text, "("},
               {:link, "https://en.wikipedia.org/wiki/Foo_(bar)"},
               {:text, ")"}
             ]

      assert LinkedText.parts("[https://example.com/a]") == [
               {:text, "["},
               {:link, "https://example.com/a"},
               {:text, "]"}
             ]
    end

    test "a long run after an address costs no more than its length" do
      for run <- [")", ".", "?", "]."] do
        small = "https://a.example/" <> String.duplicate(run, 5_000)
        large = "https://a.example/" <> String.duplicate(run, 50_000)

        {small_work, [{:link, "https://a.example/"} | _rest]} =
          reductions(fn -> LinkedText.parts(small) end)

        {large_work, [{:link, "https://a.example/"}, {:text, tail}]} =
          reductions(fn -> LinkedText.parts(large) end)

        assert byte_size(tail) == byte_size(large) - byte_size("https://a.example/")
        # Ten times the input in about ten times the work; a quadratic pass
        # would take a hundred times as much.
        assert large_work < small_work * 15
      end
    end

    test "an address longer than 2048 bytes stays text" do
      long = "https://a.example/" <> String.duplicate("a", 2_100)
      assert LinkedText.parts(long) == [{:text, long}]

      fits = "https://a.example/" <> String.duplicate("a", 2_000)
      assert LinkedText.parts(fits) == [{:link, fits}]
    end

    test "links no other scheme and no address without a host" do
      for text <- ["javascript:alert(1)", "ftp://example.com", "mailto:a@example.com", "https://"] do
        assert LinkedText.parts(text) == [{:text, text}]
      end
    end

    test "a place that is only an address is one link" do
      assert LinkedText.parts("https://meet.example.com/room") == [
               {:link, "https://meet.example.com/room"}
             ]
    end
  end

  describe "linked_text/1" do
    test "renders the links safely and escapes the text around them" do
      html =
        render_component(&LinkedText.linked_text/1,
          text: ~s|<b>Room</b> https://example.com/?a=1&b="2" ok|
        )

      assert html =~ "&lt;b&gt;Room&lt;/b&gt; "
      refute html =~ "<b>"

      assert html =~
               ~s|href="https://example.com/?a=1&amp;b="|

      assert html =~ ~s|target="_blank"|
      assert html =~ ~s|rel="noopener noreferrer"|
      assert html =~ ">https://example.com/?a=1&amp;b=</a>&quot;2&quot; ok"
    end
  end

  # The work `fun` does, in reductions, and its result. Unlike wall-clock
  # time, the count does not move when the machine is busy. A fresh process
  # keeps the test's own work out of it.
  defp reductions(fun) do
    task =
      Task.async(fn ->
        {:reductions, before} = Process.info(self(), :reductions)
        result = fun.()
        {:reductions, later} = Process.info(self(), :reductions)
        {later - before, result}
      end)

    Task.await(task)
  end
end
