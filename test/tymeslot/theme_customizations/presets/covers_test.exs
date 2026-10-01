defmodule Tymeslot.ThemeCustomizations.Presets.CoversTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Presets.Covers

  defp static_path(url), do: Path.join(Application.app_dir(:tymeslot, "priv/static"), url)

  test "every cover's image and thumbnail ship under priv/static" do
    covers = Covers.all()
    assert covers != %{}

    missing =
      for {id, cover} <- covers,
          url <- [cover.src, cover.thumb],
          not File.exists?(static_path(url)),
          do: {id, url}

    assert missing == []
  end

  # The spec reuses the background images as covers under the same ids, so
  # an organiser sees the same image under the same name in both pickers.
  test "a cover reusing a background image shows it under the background's name" do
    reused =
      for {id, cover} <- Covers.all(),
          image = Presets.find_preset_by_id(:image, "preset:" <> id),
          do: {id, cover, image}

    assert length(reused) >= 4

    assert Enum.reject(reused, fn {_id, cover, image} ->
             cover.name == image.name and cover.src == Background.preset_image_url(image.file)
           end) == []
  end

  # A cover of its own (not a reused background) is a Pixabay image whose
  # source page is recorded beside it, so its licence can be traced.
  test "a cover of its own records its Pixabay source page" do
    own =
      for {id, cover} <- Covers.all(),
          String.starts_with?(cover.src, "/images/themes/covers/"),
          do: {id, cover}

    assert own |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ~w(botanical paper-texture studio-light)

    assert Enum.reject(own, fn {_id, cover} ->
             match?("https://pixabay.com/" <> _rest, cover[:source]) and
               String.starts_with?(cover.thumb, "/images/themes/covers/")
           end) == []
  end

  test "the facade finds covers by id, and offers no cover the spec rules out" do
    assert Presets.find_preset_by_id(:cover, "ocean-sunset") == Covers.all()["ocean-sunset"]
    assert Presets.find_preset_by_id(:cover, "space-satellite") == nil
    assert Presets.find_preset_by_id(:cover, "custom") == nil

    taken = Presets.take(:cover, ["rustic-farmhouse", "nope", "artistic-studio"])
    assert Enum.map(taken, &elem(&1, 0)) == ["rustic-farmhouse", "artistic-studio"]
  end
end
