-- =====================================================================
-- HISTÓRICO DA ROTINA DA LOJA (abertura / fechamento)
-- Projeto Supabase: maquinas-daricake. Aplicado em 2026-11-07 (migrações
-- "rotina_historico" e "rotina_registrar_ignora_sem_id"; este arquivo já traz a versão final).
-- Padrão: tabelas com prefixo rotina_, views com prefixo rotina_v_.
-- Horários: guardados em UTC (timestamptz); as views mostram hora de São Paulo.
-- Para recriar do zero em outro projeto: rode este arquivo inteiro no SQL Editor
-- (precisa existir antes a função public.is_staff(), do painel de Máquinas).
-- =====================================================================

-- 1) CATÁLOGO DE ITENS (tabela de apoio: o que existe em cada rotina)
create table public.rotina_itens (
  codigo     text primary key,
  rotina     text not null check (rotina in ('abertura', 'fechamento')),
  ordem      smallint not null,
  nome       text not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  unique (rotina, ordem)
);
comment on table  public.rotina_itens is 'Catálogo dos itens das rotinas de abertura e fechamento (tabela de apoio, uma linha por item).';
comment on column public.rotina_itens.codigo is 'Código estável do item, ex.: abertura_cones. É o que o app envia.';
comment on column public.rotina_itens.rotina is 'abertura ou fechamento.';
comment on column public.rotina_itens.ordem  is 'Posição do item na lista da rotina (1 = primeiro).';
comment on column public.rotina_itens.nome   is 'Texto do item como aparece no app.';
comment on column public.rotina_itens.ativo  is 'false = item aposentado (some das views de dia, histórico continua).';

insert into public.rotina_itens (codigo, rotina, ordem, nome) values
  ('abertura_cones',      'abertura',   1, 'Posicionar os cones no estacionamento'),
  ('abertura_lixo',       'abertura',   2, 'Colocar a sacola de lixo na árvore dos entregadores'),
  ('abertura_cafe',       'abertura',   3, 'Colocar a garrafa de café'),
  ('abertura_acucar',     'abertura',   4, 'Colocar o açúcar com a colher'),
  ('abertura_copos',      'abertura',   5, 'Colocar os copos descartáveis'),
  ('fechamento_cones',    'fechamento', 1, 'Recolher os cones do estacionamento'),
  ('fechamento_lixo',     'fechamento', 2, 'Tirar a sacola de lixo da árvore'),
  ('fechamento_cafe',     'fechamento', 3, 'Guardar a garrafa de café'),
  ('fechamento_acucar',   'fechamento', 4, 'Guardar o açúcar e a colher'),
  ('fechamento_copos',    'fechamento', 5, 'Guardar os copos descartáveis'),
  ('fechamento_cadeiras', 'fechamento', 6, 'Subir de volta as cadeiras dos entregadores');

-- 2) EVENTOS (tabela de fatos: só entra linha nova, nunca se altera)
create table public.rotina_eventos (
  id           bigint generated always as identity primary key,
  id_cliente   uuid not null unique,
  tipo         text not null check (tipo in ('item_feito', 'item_conferido', 'lista_limpa')),
  rotina       text not null check (rotina in ('abertura', 'fechamento')),
  item_codigo  text references public.rotina_itens (codigo),
  data_ref     date not null,
  ocorreu_em   timestamptz not null,
  recebido_em  timestamptz not null default now(),
  dispositivo  text not null,
  responsavel  text,
  check ((tipo = 'lista_limpa') = (item_codigo is null))
);
create index rotina_eventos_dia_idx  on public.rotina_eventos (data_ref, rotina);
create index rotina_eventos_item_idx on public.rotina_eventos (item_codigo, ocorreu_em);
comment on table  public.rotina_eventos is 'Log de tudo que acontece nas rotinas (uma linha por evento). Só recebe inserções, pela função rotina_registrar.';
comment on column public.rotina_eventos.id_cliente  is 'UUID gerado no tablet. Evita duplicar quando o envio é repetido (internet instável).';
comment on column public.rotina_eventos.tipo        is 'item_feito = foto confirmada; item_conferido = gestor conferiu (fotos apagadas); lista_limpa = gestor zerou a lista.';
comment on column public.rotina_eventos.item_codigo is 'FK para rotina_itens. Vazio só em lista_limpa.';
comment on column public.rotina_eventos.data_ref    is 'Dia do evento no fuso de São Paulo (calculado no servidor).';
comment on column public.rotina_eventos.ocorreu_em  is 'Hora em que aconteceu, segundo o relógio do tablet (UTC).';
comment on column public.rotina_eventos.recebido_em is 'Hora em que o servidor recebeu (UTC). Diferença grande = tablet ficou offline ou relógio errado.';
comment on column public.rotina_eventos.dispositivo is 'Código anônimo do tablet que enviou.';
comment on column public.rotina_eventos.responsavel is 'Quem fez (nome exibido no app), texto livre.';

-- 3) FUNÇÃO DE REGISTRO (única porta de entrada para o app sem login)
create or replace function public.rotina_registrar(p_eventos jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  e jsonb; v_id uuid; v_tipo text; v_rot text; v_item text; v_em timestamptz;
  v_disp text; v_resp text;
  v_ok uuid[] := '{}'; v_rej uuid[] := '{}'; v_inv int := 0;
begin
  if p_eventos is null or jsonb_typeof(p_eventos) <> 'array' or jsonb_array_length(p_eventos) > 100 then
    return jsonb_build_object('ok', false, 'erro', 'lote_invalido');
  end if;
  for e in select value from jsonb_array_elements(p_eventos) loop
    v_id := null;
    begin
      v_id := (e->>'id')::uuid;
      if v_id is null then v_inv := v_inv + 1; continue; end if;
      v_tipo := e->>'tipo';
      v_rot  := e->>'rotina';
      v_item := nullif(btrim(e->>'item'), '');
      v_em   := (e->>'em')::timestamptz;
      v_disp := left(coalesce(nullif(btrim(e->>'disp'), ''), 'desconhecido'), 64);
      v_resp := left(nullif(btrim(e->>'resp'), ''), 60);
      if coalesce(
           v_tipo in ('item_feito', 'item_conferido', 'lista_limpa')
           and v_rot in ('abertura', 'fechamento')
           and v_em between now() - interval '60 days' and now() + interval '10 minutes'
           and ((v_tipo = 'lista_limpa') = (v_item is null))
           and (v_item is null or exists (select 1 from public.rotina_itens where codigo = v_item and rotina = v_rot)),
           false) = false then
        v_rej := v_rej || v_id;
        continue;
      end if;
      insert into public.rotina_eventos (id_cliente, tipo, rotina, item_codigo, data_ref, ocorreu_em, dispositivo, responsavel)
      values (v_id, v_tipo, v_rot, v_item, (v_em at time zone 'America/Sao_Paulo')::date, v_em, v_disp, v_resp)
      on conflict (id_cliente) do nothing;
      v_ok := v_ok || v_id;
    exception when others then
      if v_id is not null then v_rej := v_rej || v_id; else v_inv := v_inv + 1; end if;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'aceitos', to_jsonb(v_ok), 'rejeitados', to_jsonb(v_rej), 'invalidos', v_inv);
end $fn$;
comment on function public.rotina_registrar(jsonb) is 'Recebe um lote (até 100) de eventos do app: [{id, tipo, rotina, item, em, disp, resp}]. Valida tudo, ignora repetidos e devolve aceitos/rejeitados.';

-- 4) VIEWS PARA ANÁLISE (hora de São Paulo, nomes em português, prontas para Excel/Sheets/BI)
create or replace function public.rotina_dia_semana(d date)
returns text language sql immutable set search_path to ''
as $$ select (array['segunda','terça','quarta','quinta','sexta','sábado','domingo'])[extract(isodow from d)::int] $$;

create view public.rotina_v_historico with (security_invoker = true) as
select
  e.id,
  e.data_ref                                              as data,
  public.rotina_dia_semana(e.data_ref)                    as dia_semana,
  e.rotina,
  e.tipo,
  e.item_codigo,
  i.nome                                                  as item,
  i.ordem                                                 as item_ordem,
  (e.ocorreu_em at time zone 'America/Sao_Paulo')         as ocorreu_em_sp,
  to_char(e.ocorreu_em at time zone 'America/Sao_Paulo', 'HH24:MI:SS') as hora_sp,
  (e.recebido_em at time zone 'America/Sao_Paulo')        as recebido_em_sp,
  round(extract(epoch from (e.recebido_em - e.ocorreu_em)))::int as atraso_envio_s,
  e.responsavel,
  e.dispositivo,
  e.id_cliente
from public.rotina_eventos e
left join public.rotina_itens i on i.codigo = e.item_codigo;
comment on view public.rotina_v_historico is 'Um evento por linha, com nomes e hora de São Paulo. Use para auditar tudo que aconteceu.';

create view public.rotina_v_itens_dia with (security_invoker = true) as
with dias as (
  select distinct data_ref, rotina from public.rotina_eventos
), limpa as (
  select data_ref, rotina, max(ocorreu_em) as ult
  from public.rotina_eventos where tipo = 'lista_limpa' group by 1, 2
), base as (
  select d.data_ref, d.rotina, i.codigo as item_codigo, i.nome as item, i.ordem,
    (select max(f.ocorreu_em) from public.rotina_eventos f
      where f.data_ref = d.data_ref and f.rotina = d.rotina and f.item_codigo = i.codigo
        and f.tipo = 'item_feito' and f.ocorreu_em > coalesce(l.ult, '-infinity')) as feito_em
  from dias d
  join public.rotina_itens i on i.rotina = d.rotina and i.ativo
  left join limpa l on l.data_ref = d.data_ref and l.rotina = d.rotina
)
select
  b.data_ref                                       as data,
  public.rotina_dia_semana(b.data_ref)             as dia_semana,
  b.rotina, b.item_codigo, b.item, b.ordem         as item_ordem,
  (b.feito_em is not null)                         as feito,
  (b.feito_em at time zone 'America/Sao_Paulo')    as feito_em_sp,
  (select max(c.ocorreu_em) from public.rotina_eventos c
    where c.data_ref = b.data_ref and c.rotina = b.rotina and c.item_codigo = b.item_codigo
      and c.tipo = 'item_conferido' and c.ocorreu_em >= b.feito_em) is not null as conferido,
  ((select max(c.ocorreu_em) from public.rotina_eventos c
    where c.data_ref = b.data_ref and c.rotina = b.rotina and c.item_codigo = b.item_codigo
      and c.tipo = 'item_conferido' and c.ocorreu_em >= b.feito_em) at time zone 'America/Sao_Paulo') as conferido_em_sp
from base b;
comment on view public.rotina_v_itens_dia is 'Uma linha por dia x rotina x item: foi feito? a que horas? foi conferido? (considera "lista limpa").';

create view public.rotina_v_dia with (security_invoker = true) as
select
  data, dia_semana, rotina,
  count(*)                                         as itens_total,
  count(*) filter (where feito)                    as itens_feitos,
  count(*) filter (where conferido)                as itens_conferidos,
  (count(*) filter (where feito) = count(*))       as completo,
  min(feito_em_sp)                                 as primeiro_item_sp,
  max(feito_em_sp)                                 as ultimo_item_sp,
  round(extract(epoch from (max(feito_em_sp) - min(feito_em_sp))) / 60)::int as duracao_min,
  max(conferido_em_sp)                             as conferido_em_sp,
  string_agg(item, ', ' order by item_ordem) filter (where not feito) as faltaram
from public.rotina_v_itens_dia
group by data, dia_semana, rotina;
comment on view public.rotina_v_dia is 'Resumo por dia x rotina: itens feitos/total, primeiro e último horário, duração, conferência e o que faltou.';

-- 5) SEGURANÇA: app sem login só consegue chamar rotina_registrar; equipe logada só lê.
alter table public.rotina_itens   enable row level security;
alter table public.rotina_eventos enable row level security;
create policy equipe_ler on public.rotina_itens   for select to authenticated using (public.is_staff());
create policy equipe_ler on public.rotina_eventos for select to authenticated using (public.is_staff());

revoke all on public.rotina_itens, public.rotina_eventos from anon, authenticated;
grant select on public.rotina_itens, public.rotina_eventos to authenticated;
revoke all on public.rotina_v_historico, public.rotina_v_itens_dia, public.rotina_v_dia from anon, authenticated;
grant select on public.rotina_v_historico, public.rotina_v_itens_dia, public.rotina_v_dia to authenticated;

revoke all on function public.rotina_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.rotina_registrar(jsonb) to anon, authenticated;
revoke all on function public.rotina_dia_semana(date) from public, anon;
grant execute on function public.rotina_dia_semana(date) to authenticated;
