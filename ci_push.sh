#!/usr/bin/env bash
# Commit + push des fichiers générés par un workflow de scrape.
#
# Usage : ./ci_push.sh "<message de commit>" <fichiers/globs à ajouter…>
#
# POURQUOI CE SCRIPT EXISTE
# La boucle inline qu'il remplace avait deux défauts, révélés par le run
# 34410068048 (extensions-scrape) :
#
# 1. Elle ne se remettait pas d'un conflit. Après un premier
#    `git pull --rebase` en conflit, l'arbre reste à mi-rebase, donc les
#    tentatives 2, 3 et 4 échouaient toutes sur « Pulling is not possible
#    because you have unmerged files ». Quatre essais pour une seule chance
#    réelle.
#
# 2. Elle n'avait aucune politique de résolution. Or le conflit est
#    structurel : pilates_idf_data.json est régénéré par extensions-scrape ET
#    par pilates-aggregate. Deux workflows qui produisent le même fichier
#    dérivé finiront toujours par se croiser.
#
# POLITIQUE DE RÉSOLUTION : la version fraîchement générée gagne.
# Ces fichiers sont des SORTIES, pas des sources — ils sont recalculés
# intégralement à chaque run à partir des stores. Reprendre la version d'en
# face ne conserverait rien d'utile, et le prochain run l'écraserait de toute
# façon. Pendant un rebase, notre commit est le côté « theirs ».
#
# Ce raccourci ne vaut QUE pour du dérivé, d'où la liste blanche ci-dessous.
# Sur un store accumulé (padel_idf_data.json, un *_data.json de marque, une
# archive .gz, un *_resolved.json), les deux côtés portent des observations
# DISTINCTES : en écraser un perd de la donnée. Dans ce cas on ne tranche pas,
# on échoue bruyamment et un humain regarde.
set -uo pipefail

# Fichiers intégralement recalculés à chaque run : les écraser ne perd rien.
est_derive() {
  case "$1" in
    pilates_idf_data.json|yoga_idf_data.json) return 0 ;;
    padel_etude_kpis.json|padel_insights_data.json) return 0 ;;
    padel_anomalies.json|padel_club_unified.json) return 0 ;;
    *.html|*_seances.csv|*_creneaux.csv) return 0 ;;
    *) return 1 ;;
  esac
}

MSG="${1:?message de commit attendu}"; shift
BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add -A -- "$@" 2>/dev/null || true
if git diff --cached --quiet; then
  echo "Aucun changement."
  exit 0
fi
git commit -m "$MSG"

ok=0
for i in 1 2 3 4; do
  # Repartir d'un arbre sain : sans ça, un conflit au tour 1 condamne les suivants.
  git rebase --abort 2>/dev/null || true

  if git pull --rebase --autostash origin "$BRANCH"; then
    if git push; then ok=1; break; fi
  else
    conflits="$(git diff --name-only --diff-filter=U)"
    if [ -n "$conflits" ]; then
      accumules=""
      for f in $conflits; do
        est_derive "$f" || accumules="$accumules $f"
      done
      if [ -n "$accumules" ]; then
        git rebase --abort 2>/dev/null || true
        echo "::error::conflit sur un store accumulé :$accumules"
        echo "::error::les deux versions portent des observations distinctes, "
        echo "::error::je ne tranche pas automatiquement — résolution manuelle requise."
        exit 1
      fi
      echo "conflit sur du dérivé ($conflits) — on garde la version de ce run"
      for f in $conflits; do
        git checkout --theirs -- "$f" 2>/dev/null || true
        git add -- "$f"
      done
      if GIT_EDITOR=true git rebase --continue && git push; then ok=1; break; fi
    fi
  fi
  echo "retry push $i"
  sleep 5
done

if [ "$ok" != 1 ]; then
  git rebase --abort 2>/dev/null || true
  echo "::error::push impossible après 4 tentatives — les données de ce run ne sont PAS persistées"
  exit 1
fi
echo "push OK"
