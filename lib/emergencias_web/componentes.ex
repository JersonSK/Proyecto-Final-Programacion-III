defmodule EmergenciasWeb.Componentes do
  @moduledoc """
  Piezas visuales reutilizables del panel: insignias de estado, tarjetas de
  indicadores, barras de progreso y los formularios de acciones, que se generan a
  partir de la definición de opciones de `Emergencias.CLI.Menu` (los mismos datos,
  catálogos y permisos que usa el menú de la consola).
  """

  use Phoenix.Component

  alias Emergencias.CLI.Formato

  # ---------------------------------------------------------------------------
  # Textos
  # ---------------------------------------------------------------------------

  @doc "Etiqueta legible de un átomo o texto (`en_atencion` → `en atención`)."
  def texto(nil), do: "—"
  def texto(""), do: "—"

  def texto(valor) when is_atom(valor) or is_binary(valor) do
    valor
    |> Formato.etiqueta()
    |> String.replace("atencion", "atención")
    |> String.replace("critico", "crítico")
    |> String.replace("critica", "crítica")
    |> String.replace("informacion", "información")
    |> String.replace("pequeno", "pequeño")
    |> String.replace("analgesicos", "analgésicos")
    |> String.replace("antibioticos", "antibióticos")
  end

  def texto(valor), do: to_string(valor)

  def fecha(valor), do: Formato.fecha(valor)

  @doc "Porcentaje entero de `parte` sobre `total` (0 si el total es 0)."
  def porcentaje(_parte, 0), do: 0
  def porcentaje(parte, total), do: round(parte * 100 / total)

  # ---------------------------------------------------------------------------
  # Insignias (badges) con color según el valor
  # ---------------------------------------------------------------------------

  attr :valor, :any, required: true

  def insignia(assigns) do
    ~H"""
    <span class={"insignia insignia-#{tono(@valor)}"}>{texto(@valor)}</span>
    """
  end

  defp tono(valor) when valor in [:critica, :critico, :sin_informacion, :perdida], do: "rojo"
  defp tono(valor) when valor in [:alta, :alto, :reportada, :pendiente, :activa], do: "ambar"

  defp tono(valor)
       when valor in [
              :media,
              :medio,
              :asignada,
              :en_atencion,
              :trasladada,
              :en_albergue,
              :posible_coincidencia,
              :encontrada
            ],
       do: "azul"

  defp tono(valor)
       when valor in [:baja, :bajo, :atendida, :localizada, :reunificada, :entregado, :resuelta],
       do: "verde"

  defp tono(_valor), do: "gris"

  # ---------------------------------------------------------------------------
  # Indicadores y barras
  # ---------------------------------------------------------------------------

  attr :titulo, :string, required: true
  attr :valor, :any, required: true
  attr :detalle, :string, default: nil
  attr :tono, :string, default: "neutro"

  def indicador(assigns) do
    ~H"""
    <div class={"indicador indicador-#{@tono}"}>
      <span class="indicador-titulo">{@titulo}</span>
      <strong class="indicador-valor">{@valor}</strong>
      <span :if={@detalle} class="indicador-detalle">{@detalle}</span>
    </div>
    """
  end

  attr :valor, :integer, required: true
  attr :maximo, :integer, required: true

  def barra(assigns) do
    assigns = assign(assigns, :pct, min(porcentaje(assigns.valor, assigns.maximo), 100))

    ~H"""
    <div
      class={"barra #{tono_barra(@pct)}"}
      role="progressbar"
      aria-valuenow={@pct}
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <span style={"width: #{@pct}%"}></span>
    </div>
    """
  end

  defp tono_barra(pct) when pct >= 90, do: "barra-roja"
  defp tono_barra(pct) when pct >= 70, do: "barra-ambar"
  defp tono_barra(_pct), do: "barra-verde"

  attr :titulo, :string, required: true
  attr :class, :string, default: nil
  slot :acciones
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["panel", @class]}>
      <header class="panel-cabecera">
        <h2>{@titulo}</h2>
        <div :if={@acciones != []} class="panel-acciones">{render_slot(@acciones)}</div>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :mensaje, :string, default: "Sin resultados."

  def vacio(assigns) do
    ~H"""
    <p class="vacio">{@mensaje}</p>
    """
  end

  # ---------------------------------------------------------------------------
  # Formularios de acciones generados desde las opciones del menú
  # ---------------------------------------------------------------------------

  @doc """
  Un formulario por opción del menú. Cada campo se dibuja según su tipo
  (`:texto` obligatorio, `:opcional`, `:opcion` como lista desplegable...).
  Al enviarse, el panel arma la misma línea de comando que escribiría el usuario.
  """
  attr :opcion, :map, required: true
  attr :seccion, :integer, required: true
  attr :indice, :integer, required: true

  def formulario_accion(assigns) do
    assigns = assign(assigns, :campos, Enum.with_index(assigns.opcion.campos))

    ~H"""
    <details class="accion">
      <summary>{@opcion.texto}</summary>
      <form phx-submit="accion" class="formulario formulario-accion">
        <input type="hidden" name="seccion" value={@seccion} />
        <input type="hidden" name="opcion" value={@indice} />
        <.campo :for={{campo, i} <- @campos} campo={campo} nombre={"c#{i}"} />
        <p :if={@campos == []} class="tenue">No necesita datos.</p>
        <button type="submit" class="boton boton-primario">Ejecutar</button>
      </form>
    </details>
    """
  end

  attr :campo, :any, required: true
  attr :nombre, :string, required: true

  defp campo(%{campo: {:filtro, _clave, interno}} = assigns),
    do: campo(assign(assigns, :campo, interno))

  defp campo(%{campo: {:texto, etiqueta}} = assigns) do
    assigns = assign(assigns, etiqueta: etiqueta, lista: lista_de(etiqueta))

    ~H"""
    <label>
      {@etiqueta}
      <input type="text" name={@nombre} list={@lista} required />
    </label>
    """
  end

  defp campo(%{campo: {:opcional, etiqueta, _defecto}} = assigns) do
    assigns = assign(assigns, etiqueta: etiqueta, lista: lista_de(etiqueta))

    ~H"""
    <label>
      {@etiqueta} <span class="tenue">(opcional)</span>
      <input type="text" name={@nombre} list={@lista} />
    </label>
    """
  end

  defp campo(%{campo: {tipo, etiqueta, valores}} = assigns)
       when tipo in [:opcion, :opcion_opcional] do
    assigns =
      assign(assigns,
        etiqueta: etiqueta,
        obligatorio: tipo == :opcion,
        valores: Enum.map(valores, &valor_y_etiqueta/1)
      )

    ~H"""
    <label>
      {@etiqueta} <span :if={!@obligatorio} class="tenue">(opcional)</span>
      <select name={@nombre} required={@obligatorio}>
        <option value="">{if @obligatorio, do: "Elija…", else: "—"}</option>
        <option :for={{valor, texto} <- @valores} value={valor}>{texto}</option>
      </select>
    </label>
    """
  end

  defp valor_y_etiqueta({valor, etiqueta}), do: {valor, etiqueta}
  defp valor_y_etiqueta(valor), do: {valor, texto(valor)}

  # Sugiere los códigos de zonas/albergues en los campos que los piden.
  defp lista_de(etiqueta) do
    if String.match?(
         String.downcase(etiqueta),
         ~r/zona|sector|ubicaci|albergue|punto|origen|destino/u
       ),
       do: "lugares",
       else: nil
  end

  @doc "Valores sugeridos (datalist) con todos los códigos de lugares."
  attr :lugares, :list, required: true

  def lista_lugares(assigns) do
    ~H"""
    <datalist id="lugares">
      <option :for={{codigo, nombre} <- @lugares} value={codigo}>{nombre}</option>
    </datalist>
    """
  end
end
