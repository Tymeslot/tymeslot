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

  @callback transcode(source_path :: String.t(), output_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, String.t()}

  @callback available?() :: boolean()
end
