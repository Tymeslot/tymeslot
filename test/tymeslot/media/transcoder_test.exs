defmodule Tymeslot.Media.TranscoderTest do
  # available?/0 answers from the OS PATH, which is process-global, so the two
  # tests that narrow it cannot run alongside anything else.
  use ExUnit.Case, async: false

  @moduletag :workers

  alias Tymeslot.Media.Transcoder

  describe "available?/0" do
    # Asserting that ffmpeg is simply present would test the machine running
    # the suite rather than Tymeslot: it holds on a developer's box and fails
    # on a CI runner, which ships no ffmpeg. Supplying the PATH makes both
    # answers reproducible anywhere, and still catches the mistake that
    # matters, a wrong executable name.
    @tag :tmp_dir
    test "finds ffmpeg on the PATH", %{tmp_dir: tmp_dir} do
      stub = Path.join(tmp_dir, "ffmpeg")
      File.write!(stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(stub, 0o755)

      assert with_path(tmp_dir, &Transcoder.available?/0)
    end

    @tag :tmp_dir
    test "reports ffmpeg unavailable when the PATH holds no such executable", %{tmp_dir: tmp_dir} do
      refute with_path(tmp_dir, &Transcoder.available?/0)
    end
  end

  describe "variant_definitions/0" do
    test "returns all four variant definitions" do
      variants = Transcoder.variant_definitions()
      assert length(variants) == 4

      suffixes = Enum.map(variants, & &1.suffix)
      assert "-desktop.webm" in suffixes
      assert "-desktop.mp4" in suffixes
      assert "-mobile.mp4" in suffixes
      assert "-low.mp4" in suffixes
    end
  end

  describe "derive_variant_paths/1" do
    test "derives variant paths from original upload path" do
      paths = Transcoder.derive_variant_paths("/uploads/videos/abc123.mp4")

      assert paths == [
               "/uploads/videos/abc123-desktop.webm",
               "/uploads/videos/abc123-desktop.mp4",
               "/uploads/videos/abc123-mobile.mp4",
               "/uploads/videos/abc123-low.mp4"
             ]
    end

    test "handles filenames with multiple dots" do
      paths = Transcoder.derive_variant_paths("/uploads/videos/my.file.name.mp4")

      assert paths == [
               "/uploads/videos/my.file.name-desktop.webm",
               "/uploads/videos/my.file.name-desktop.mp4",
               "/uploads/videos/my.file.name-mobile.mp4",
               "/uploads/videos/my.file.name-low.mp4"
             ]
    end
  end

  # Runs `fun` with the PATH narrowed to `dir`, restoring the caller's PATH
  # afterwards so a failure cannot leave the suite unable to find anything.
  defp with_path(dir, fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", dir)

    try do
      fun.()
    after
      restore_path(original)
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(original), do: System.put_env("PATH", original)
end
