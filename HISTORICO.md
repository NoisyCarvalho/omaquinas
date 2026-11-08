# Histórico da Rotina da loja

Registro, com data e hora, de tudo que acontece nas rotinas de **abertura** e **fechamento**. Os dados ficam no Supabase (projeto `maquinas-daricake`, o mesmo do painel de Máquinas) e podem ser analisados **fora do Claude**: Excel, Google Sheets, Power BI, Looker Studio ou SQL.

Horários: o banco guarda em UTC; todas as views e CSVs já mostram **hora de São Paulo**.

## 1. Como os dados chegam

```
Tablet (app Rotina) ──► fila no tablet (funciona sem internet)
                     └─► função rotina_registrar ──► tabela rotina_eventos
                                                       │
                                  views rotina_v_* ◄───┘ (equipe logada lê)
```

- Cada ação vira um **evento**: `item_feito` (foto confirmada), `item_conferido` (gestor conferiu e apagou a foto) e `lista_limpa` (gestor zerou a lista).
- Se estiver sem internet, o evento fica na fila do tablet e sobe sozinho depois. Cada evento tem um UUID, então reenvio nunca duplica.
- **Fotos não vão para o banco.** Continuam só no tablet e são apagadas na conferência.

## 2. O que existe no banco (dicionário de dados)

Todas as tabelas e colunas também têm descrição dentro do Supabase (aba *Table editor*).

### Tabelas

| Tabela | Para que serve |
|---|---|
| `rotina_itens` | Catálogo: uma linha por item de cada rotina (código, rotina, ordem, nome, ativo). |
| `rotina_eventos` | Log: uma linha por evento. Só recebe inserções. |

`rotina_eventos`: `id`, `id_cliente` (UUID do tablet), `tipo`, `rotina`, `item_codigo`, `data_ref` (dia em SP), `ocorreu_em` (relógio do tablet, UTC), `recebido_em` (relógio do servidor, UTC), `dispositivo`, `responsavel`.

### Views (use estas para analisar)

| View | Uma linha por... | Colunas principais |
|---|---|---|
| `rotina_v_dia` | dia × rotina | `data`, `dia_semana`, `rotina`, `itens_total`, `itens_feitos`, `itens_conferidos`, `completo`, `primeiro_item_sp`, `ultimo_item_sp`, `duracao_min`, `conferido_em_sp`, `faltaram` |
| `rotina_v_itens_dia` | dia × rotina × item | `data`, `rotina`, `item_codigo`, `item`, `item_ordem`, `feito`, `feito_em_sp`, `conferido`, `conferido_em_sp` |
| `rotina_v_historico` | evento | `data`, `dia_semana`, `rotina`, `tipo`, `item`, `ocorreu_em_sp`, `hora_sp`, `recebido_em_sp`, `atraso_envio_s`, `responsavel`, `dispositivo` |

Regras importantes:
- `rotina_v_dia` e `rotina_v_itens_dia` só têm os dias em que **houve algum evento**. Para achar dias em que ninguém fez a rotina, veja a consulta 4 abaixo.
- Se o gestor usa "Limpar esta lista", só contam os itens feitos **depois** da limpeza.
- `atraso_envio_s` = `recebido_em` − `ocorreu_em`. Valor grande: o tablet ficou sem internet. Valor negativo ou absurdo: o relógio do tablet está errado.
- Item aposentado (`ativo = false`) some das views de dia, mas continua em `rotina_v_historico`.

## 3. Como analisar fora do Claude

**a) Pelo app (mais simples).** Início → **Histórico** → entrar com o e-mail e a senha da equipe (as mesmas do painel de Máquinas) → botões **CSV**: resumo por dia, itens por dia ou todos os eventos. Os arquivos abrem direto no Excel e no Google Sheets (acentos corretos). O filtro de período e de rotina vale para o CSV. Limite do app: até 1.000 linhas por arquivo.

**b) Pelo painel do Supabase.** *Table Editor* → escolha a view → **Export → CSV** (sem limite de 1.000 linhas). Ou *SQL Editor* para rodar as consultas abaixo.

**c) Planilha ou BI conectado direto.** Google Sheets, Power BI e Looker Studio conectam no Postgres do Supabase (*Project Settings → Database → Connection string*). Recomendado criar antes um usuário **somente leitura** só para as views `rotina_v_*` (não use a senha do administrador). Ainda não foi criado.

## 4. Consultas prontas (SQL Editor)

Todas foram testadas no banco.

```sql
-- 1) Conclusão por semana (% de dias com a rotina completa)
select date_trunc('week', data)::date as semana, rotina,
       count(*) as dias, count(*) filter (where completo) as dias_completos,
       round(100.0 * count(*) filter (where completo) / count(*)) as pct
from rotina_v_dia group by 1, 2 order by 1 desc, 2;

-- 2) Itens mais esquecidos
select rotina, item, count(*) filter (where not feito) as vezes_sem_fazer, count(*) as dias
from rotina_v_itens_dia group by rotina, item, item_ordem
order by vezes_sem_fazer desc, rotina, item_ordem;

-- 3) Horário médio de início e fim, por dia da semana
select dia_semana, rotina,
       to_char(time '00:00' + avg(primeiro_item_sp::time - time '00:00'), 'HH24:MI') as inicio_medio,
       to_char(time '00:00' + avg(ultimo_item_sp::time - time '00:00'), 'HH24:MI') as fim_medio,
       round(avg(duracao_min)) as duracao_media_min
from rotina_v_dia where itens_feitos > 0 group by dia_semana, rotina;

-- 4) Dias dos últimos 30 em que a rotina NÃO foi feita (nenhum registro)
select d::date as data, r.rotina
from generate_series((now() at time zone 'America/Sao_Paulo')::date - 30,
                     (now() at time zone 'America/Sao_Paulo')::date - 1, interval '1 day') d
cross join (values ('abertura'), ('fechamento')) r(rotina)
left join rotina_v_dia v on v.data = d::date and v.rotina = r.rotina
where v.data is null order by 1 desc;

-- 5) Tablets que enviaram com atraso (ficaram offline ou com relógio errado)
select data, dispositivo, max(atraso_envio_s) as maior_atraso_s
from rotina_v_historico where atraso_envio_s > 300 group by 1, 2 order by 1 desc;
```

## 5. Segurança (quem pode o quê)

| Quem | Pode | Não pode |
|---|---|---|
| App no tablet (sem login) | Enviar eventos pela função `rotina_registrar` (valida rotina, item, data e tamanho do lote) | Ler qualquer dado, alterar ou apagar |
| Equipe logada (`is_staff()`) | Ler tabelas e views | Inserir, alterar ou apagar direto |
| Administrador (SQL Editor) | Tudo | — |

A chave `sb_publishable_...` em `docs/config.js` é pública por natureza; a proteção está nas regras acima. Nunca coloque a chave `service_role` no repositório.

Limite conhecido: qualquer pessoa que descubra o endereço do app consegue **enviar** eventos falsos (não consegue ler nada). Por isso o servidor grava `recebido_em` e a coluna `dispositivo` permite achar envios estranhos.

## 6. Manutenção

- **Item novo na rotina:** (1) `insert` em `rotina_itens` com `codigo`, `rotina`, `ordem` e `nome`; (2) no `docs/index.html`, acrescente o item em `ROTINAS` com o campo `c` (o código é `rotina_` + `c`, ex.: `c: 'cones'` em abertura → `abertura_cones`); (3) suba o número em `docs/sw.js`. Sem o item no catálogo, o servidor recusa os eventos dele.
- **Aposentar item:** `update rotina_itens set ativo = false where codigo = '...'`.
- **Apagar dados de teste:** `delete from rotina_eventos where dispositivo = 'teste-app';`
- **Recriar o banco:** `banco/rotina_historico.sql` (versão final de tudo que foi aplicado).
- **Log do repositório:** `LOG.txt` (gerado por `./gerar-log.sh`) e `eventos-manuais.txt`.
