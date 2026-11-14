defmodule Emergencias.MixProject do
  use Mix.Project

  def project do
    [
      app: :emergencias,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # :crypto se usa para el hash de contraseñas.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Emergencias.Application, []}
    ]
  end

  # Solo la interfaz web usa dependencias externas (Phoenix + LiveView).
  # El núcleo del sistema (dominio, GenServers, consola) no depende de ellas.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.4"},
      {:bandit, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
