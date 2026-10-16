defmodule Tymeslot.ThemeCustomizations.Presets.Gradients do
  @moduledoc """
  The gradient background presets. Read through
  `Tymeslot.ThemeCustomizations.Presets`; a theme offers a gradient only when
  its background group lists the id.
  """

  @type preset :: %{required(:name) => String.t(), required(:value) => String.t()}

  @gradients %{
    "gradient_1" => %{
      name: "Aurora",
      value: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
    },
    "gradient_2" => %{
      name: "Ocean",
      value: "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)"
    },
    "gradient_3" => %{
      name: "Sunset",
      value: "linear-gradient(135deg, #FC466B 0%, #3F5EFB 100%)"
    },
    "gradient_4" => %{
      name: "Forest",
      value: "linear-gradient(135deg, #11998e 0%, #38ef7d 100%)"
    },
    "gradient_5" => %{
      name: "Berry",
      value: "linear-gradient(135deg, #4e54c8 0%, #8f94fb 100%)"
    },
    "gradient_6" => %{
      name: "Midnight",
      value: "linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%)"
    },
    "gradient_7" => %{
      name: "Coral",
      value: "linear-gradient(135deg, #fa709a 0%, #fee140 100%)"
    },
    "gradient_8" => %{
      name: "Northern Lights",
      value: "linear-gradient(135deg, #43cea2 0%, #185a9d 100%)"
    }
  }

  @doc "Every gradient, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @gradients
end
