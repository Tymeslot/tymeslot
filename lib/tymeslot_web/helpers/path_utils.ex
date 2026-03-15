defmodule TymeslotWeb.Helpers.PathUtils do
  @moduledoc """
  Shared path parsing utilities for extracting usernames from scheduling URLs.
  """

  @reserved_paths ~w(
    auth dashboard api dev assets docs admin healthcheck
    robots.txt sitemap.xml favicon.ico embed.js
  ) ++ [""]

  # File extensions that indicate a static asset, not a username.
  # Catches digested filenames like embed-<hash>.js that bypass the
  # exact-match reserved_paths list.
  @static_extensions ~w(.js .css .json .map .gz .ico .svg .png .jpg .webp .woff .woff2 .ttf)

  @spec extract_username_from_path(String.t()) :: String.t() | nil
  def extract_username_from_path(path) do
    case String.split(path, "/", parts: 3) do
      ["", username | _rest] ->
        if username in @reserved_paths or static_file?(username), do: nil, else: username

      _invalid_path ->
        nil
    end
  end

  defp static_file?(segment) do
    Enum.any?(@static_extensions, &String.ends_with?(segment, &1))
  end
end
