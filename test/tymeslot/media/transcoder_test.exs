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

  describe "transcode/3 when the source is gone" do
    @variant [codec: "libx264", max_height: 1080, format: "mp4"]

    @tag :tmp_dir
    test "reports :source_missing rather than running ffmpeg", %{tmp_dir: tmp_dir} do
      # A stub that always fails: if the source check did not short-circuit, the
      # result would be the exit-status string this writes, not :source_missing.
      stub = Path.join(tmp_dir, "ffmpeg")
      File.write!(stub, "#!/bin/sh\nexit 3\n")
      File.chmod!(stub, 0o755)

      source = Path.join(tmp_dir, "never-written.mp4")
      output = Path.join(tmp_dir, "never-written-desktop.mp4")

      assert {:error, :source_missing} =
               with_path(tmp_dir, fn -> Transcoder.transcode(source, output, @variant) end)
    end

    @tag :tmp_dir
    test "reports :source_missing when the source vanishes mid-encode", %{tmp_dir: tmp_dir} do
      # The production race: the owner replaced the background video, the theme
      # cleanup deleted this source, and ffmpeg died part-way with a plain
      # non-zero exit. The reason must not be reported as an encode failure.
      source = Path.join(tmp_dir, "going-away.mp4")
      output = Path.join(tmp_dir, "going-away-desktop.mp4")
      File.write!(source, "not really a video")

      # `with_path/2` narrows PATH to tmp_dir for the duration, so the stub has
      # to reach `rm` by absolute path rather than through a lookup.
      stub = Path.join(tmp_dir, "ffmpeg")
      File.write!(stub, "#!/bin/sh\n/bin/rm -f '#{source}'\nexit 254\n")
      File.chmod!(stub, 0o755)

      assert {:error, :source_missing} =
               with_path(tmp_dir, fn -> Transcoder.transcode(source, output, @variant) end)
    end

    @tag :tmp_dir
    test "still reports a genuine encode failure when the source survives", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "still-here.mp4")
      output = Path.join(tmp_dir, "still-here-desktop.mp4")
      File.write!(source, "not really a video")

      stub = Path.join(tmp_dir, "ffmpeg")
      File.write!(stub, "#!/bin/sh\nexit 3\n")
      File.chmod!(stub, 0o755)

      assert {:error, "ffmpeg exited with status 3"} =
               with_path(tmp_dir, fn -> Transcoder.transcode(source, output, @variant) end)
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
