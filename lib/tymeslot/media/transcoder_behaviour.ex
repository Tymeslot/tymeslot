defmodule Tymeslot.Media.TranscoderBehaviour do
  @moduledoc """
  Behaviour for video transcoding operations.
  Production implementation uses ffmpeg; tests use Mox mock.
  """

  @type variant :: %{
          suffix: String.t(),
          format: String.t(),
          max_height: pos_integer(),
          codec: String.t()
        }

  @doc """
  Produces one variant of `source_path` at `output_path`.

  `{:error, :source_missing}` reports that the source file is not there — it was
  replaced or deleted after the job was queued. It is distinct from an encode
  failure because it is terminal: the bytes are gone, so no retry can succeed.
  """
  @callback transcode(source_path :: String.t(), output_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, String.t() | :source_missing}

  @callback available?() :: boolean()
end
