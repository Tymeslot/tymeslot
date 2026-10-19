defmodule Tymeslot.Docs do
  @moduledoc """
  Links into the docs hub.

  The docs hub is a hosted site that standalone Core does not serve, so the
  default points there; an operator running their own docs sets
  `:docs_article_base_url`, and every docs link (dashboard help links,
  feature-announcement CTAs) follows. This is the single place that key is
  read and normalised.
  """

  @default_base_url "https://tymeslot.app/docs"

  @doc "The full URL of the docs article `slug`."
  @spec article_url(String.t()) :: String.t()
  def article_url(slug) when is_binary(slug), do: "#{base_url()}/#{slug}"

  # Read at runtime, not through `compile_env/3`: Core ships as a prebuilt
  # image, so a self-hoster pointing this at their own docs configures it on
  # the running instance and cannot recompile to pick up a module attribute.
  # Rendering a handful of links is not a hot path, so the lookup costs
  # nothing worth reclaiming. Trailing slashes are trimmed here so an
  # operator-set base of either form joins the slug with exactly one `/`.
  defp base_url do
    :tymeslot
    |> Application.get_env(:docs_article_base_url, @default_base_url)
    |> String.trim_trailing("/")
  end
end
