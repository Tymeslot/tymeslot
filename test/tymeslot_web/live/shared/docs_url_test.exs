defmodule TymeslotWeb.Live.Shared.DocsUrlTest do
  use ExUnit.Case, async: false
  @moduletag :docs

  alias TymeslotWeb.Live.Shared.DocsUrl

  setup do
    previous = Application.get_env(:tymeslot, :docs_article_base_url)
    on_exit(fn -> Application.put_env(:tymeslot, :docs_article_base_url, previous) end)
  end

  test "article_url composes the default base with the slug" do
    Application.delete_env(:tymeslot, :docs_article_base_url)

    assert DocsUrl.article_url("slack") == "https://tymeslot.app/docs/slack"
  end

  test "article_url follows an operator-configured base" do
    Application.put_env(:tymeslot, :docs_article_base_url, "https://docs.example.com")

    assert DocsUrl.article_url("slack") == "https://docs.example.com/slack"
  end

  test "article_url trims a trailing slash on the configured base" do
    Application.put_env(:tymeslot, :docs_article_base_url, "https://docs.example.com/")

    assert DocsUrl.article_url("slack") == "https://docs.example.com/slack"
  end

  test "article_link renders an anchor pointing at article_url" do
    Application.put_env(:tymeslot, :docs_article_base_url, "https://docs.example.com")

    assert DocsUrl.article_link("slack", "our Slack docs") ==
             ~s(<a href="https://docs.example.com/slack" target="_blank" rel="noopener noreferrer" class="font-black text-turquoise-700 hover:text-turquoise-900 underline">our Slack docs</a>)
  end
end
