defmodule Tymeslot.DocsTest do
  use ExUnit.Case, async: false
  @moduletag :docs

  alias Tymeslot.Docs

  setup do
    previous = Application.get_env(:tymeslot, :docs_article_base_url)
    on_exit(fn -> Application.put_env(:tymeslot, :docs_article_base_url, previous) end)
  end

  test "article_url composes the default base with the slug" do
    Application.delete_env(:tymeslot, :docs_article_base_url)

    assert Docs.article_url("slack") == "https://tymeslot.app/docs/slack"
  end

  test "article_url follows an operator-configured base" do
    Application.put_env(:tymeslot, :docs_article_base_url, "https://docs.example.com")

    assert Docs.article_url("slack") == "https://docs.example.com/slack"
  end

  test "article_url trims a trailing slash on the configured base" do
    Application.put_env(:tymeslot, :docs_article_base_url, "https://docs.example.com/")

    assert Docs.article_url("slack") == "https://docs.example.com/slack"
  end
end
