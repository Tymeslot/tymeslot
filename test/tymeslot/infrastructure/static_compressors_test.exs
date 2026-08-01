defmodule Tymeslot.Infrastructure.StaticCompressorsTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.StaticCompressors
  alias Tymeslot.Infrastructure.StaticCompressors.Gzip
  alias Tymeslot.Infrastructure.StaticCompressors.Zstd

  # Structured but varied, like the Tailwind output these modules actually get.
  # Content repetitive enough to compress to a few hundred bytes hits the same
  # size at every zlib level, which would make the level assertion below vacuous.
  @css Enum.map_join(1..400, fn i ->
         ".c#{i} { color: ##{Integer.to_string(rem(i * 7919, 16_777_215), 16)}; " <>
           "margin: #{rem(i, 37)}px #{rem(i, 13)}px; padding: #{rem(i, 23)}rem; }\n"
       end)

  describe "encodings/1" do
    test "offers zstd ahead of gzip in prod" do
      assert StaticCompressors.encodings(:prod) == [{"zstd", ".zst"}, {"gzip", ".gz"}]
    end

    test "offers nothing outside prod, where compressed siblings go stale" do
      assert StaticCompressors.encodings(:dev) == []
      assert StaticCompressors.encodings(:test) == []
    end
  end

  describe "compressible?/1" do
    test "accepts text-shaped assets" do
      assert StaticCompressors.compressible?("/priv/static/assets/app.css")
      assert StaticCompressors.compressible?("app.js")
      assert StaticCompressors.compressible?("logo.svg")
    end

    test "rejects already-compressed formats" do
      refute StaticCompressors.compressible?("photo.png")
      refute StaticCompressors.compressible?("clip.mp4")
      refute StaticCompressors.compressible?("app.css.gz")
    end
  end

  describe "Gzip" do
    test "produces a gzip stream the original content can be recovered from" do
      assert {:ok, compressed} = Gzip.compress_file("app.css", @css)
      assert :zlib.gunzip(compressed) == @css
    end

    test "compresses harder than :zlib.gzip/1, which the Phoenix default uses" do
      assert {:ok, compressed} = Gzip.compress_file("app.css", @css)
      assert byte_size(compressed) < byte_size(:zlib.gzip(@css))
    end

    test "declines files not worth compressing" do
      assert Gzip.compress_file("photo.png", @css) == :error
    end

    test "claims the .gz extension the digester cleans up by" do
      assert Gzip.file_extensions() == [".gz"]
    end
  end

  describe "Zstd" do
    test "produces a zstd frame the original content can be recovered from" do
      assert {:ok, compressed} = Zstd.compress_file("app.css", @css)
      assert IO.iodata_to_binary(:zstd.decompress(compressed)) == @css
    end

    test "returns a binary, not the iodata :zstd.compress/2 hands back" do
      assert {:ok, compressed} = Zstd.compress_file("app.css", @css)
      # byte_size/1 accepts only a binary, so iodata fails here rather than
      # slipping through to Plug.Static.
      assert byte_size(compressed) > 0
    end

    test "beats gzip, which is the whole reason for the extra variant" do
      assert {:ok, zstd} = Zstd.compress_file("app.css", @css)
      assert {:ok, gzip} = Gzip.compress_file("app.css", @css)
      assert byte_size(zstd) < byte_size(gzip)
    end

    test "declines files not worth compressing" do
      assert Zstd.compress_file("photo.png", @css) == :error
    end

    test "claims the .zst extension the digester cleans up by" do
      assert Zstd.file_extensions() == [".zst"]
    end
  end
end
