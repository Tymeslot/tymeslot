defmodule TymeslotWeb.Helpers.PathUtils do
  @moduledoc """
  Shared path parsing utilities for extracting usernames from scheduling URLs.
  """

  @reserved_paths ~w(
    auth dashboard api dev assets docs admin healthcheck
    robots.txt sitemap.xml favicon.ico embed.js
  ) ++ [""]

  @spec extract_username_from_path(String.t()) :: String.t() | nil
  def extract_username_from_path(path) do
    case String.split(path, "/", parts: 3) do
      ["", username | _rest] ->
        if username in @reserved_paths, do: nil, else: username

      _invalid_path ->
        nil
    end
  end
end
