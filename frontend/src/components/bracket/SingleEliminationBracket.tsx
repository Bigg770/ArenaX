"use client";

import React, { useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import {
  BracketData,
  BracketMatch,
  BracketRound,
} from "@/types/bracket";
import { BracketMatchModal } from "./BracketMatchModal";
import {
  Activity,
  AlertTriangle,
  CheckCircle2,
  ChevronRight,
  Clock3,
  HelpCircle,
  LayoutGrid,
  ListFilter,
  Sparkles,
  Table as TableIcon,
  Trophy,
  User,
} from "lucide-react";
import { cn } from "@/lib/utils";

interface SingleEliminationBracketProps {
  bracketData: BracketData;
  currentUserId?: string;
  /**
   * A match id to visually highlight and auto-scroll into view — driven by
   * the `?match=` deep-link query param (#1089).
   */
  highlightedMatchId?: string | null;
}

/** DOM id for a bracket match card, used to scroll a deep-linked match into view. */
export function bracketMatchDomId(matchId: string): string {
  return `bracket-match-${matchId}`;
}

const ROUND_WIDTH = 280;
const ROUND_GAP = 56;
const MATCH_HEIGHT = 120;
const VERTICAL_GAP = 28;
const COLUMN_HEADER_HEIGHT = 56;

/** Threshold for switching huge brackets to round-bounded DOM rendering (#32) */
const LARGE_BRACKET_MATCH_THRESHOLD = 32;

export function SingleEliminationBracket({
  bracketData,
  currentUserId,
  highlightedMatchId,
}: SingleEliminationBracketProps) {
  const [selectedMatch, setSelectedMatch] = useState<BracketMatch | null>(null);
  const [viewMode, setViewMode] = useState<"tree" | "rounds" | "table">("tree");
  const [activeRoundNumber, setActiveRoundNumber] = useState<number>(1);
  const roundTabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  // Deep link (#1089): scroll the shared match into view once its card exists.
  useEffect(() => {
    if (!highlightedMatchId) return;
    const el = document.getElementById(bracketMatchDomId(highlightedMatchId));
    el?.scrollIntoView({ behavior: "smooth", block: "center", inline: "center" });
  }, [highlightedMatchId]);

  const processedBracketData = useMemo(() => {
    const markPlayer = (player: BracketMatch["player1"]) =>
      player ? { ...player, isCurrentUser: player.id === currentUserId } : null;

    return {
      ...bracketData,
      sections: bracketData.sections.map((section) => ({
        ...section,
        rounds: section.rounds.map((round) => ({
          ...round,
          matches: round.matches.map((match) => ({
            ...match,
            player1: markPlayer(match.player1),
            player2: markPlayer(match.player2),
          })),
        })),
      })),
    };
  }, [bracketData, currentUserId]);

  const primarySection = processedBracketData.sections[0];
  const allRounds = useMemo(() => {
    return primarySection?.rounds ?? [];
  }, [primarySection]);

  const totalMatches = useMemo(() => {
    return allRounds.reduce((acc, r) => acc + r.matches.length, 0);
  }, [allRounds]);

  const isLargeBracket = totalMatches > LARGE_BRACKET_MATCH_THRESHOLD;

  const selectedRound = useMemo(() => {
    return allRounds.find((r) => r.roundNumber === activeRoundNumber) ?? allRounds[0];
  }, [allRounds, activeRoundNumber]);

  // Keyboard navigation across round tabs (#32)
  const handleRoundTabKeyDown = (
    e: React.KeyboardEvent,
    index: number,
  ) => {
    let nextIndex = index;
    if (e.key === "ArrowRight") {
      nextIndex = (index + 1) % allRounds.length;
    } else if (e.key === "ArrowLeft") {
      nextIndex = (index - 1 + allRounds.length) % allRounds.length;
    } else if (e.key === "Home") {
      nextIndex = 0;
    } else if (e.key === "End") {
      nextIndex = allRounds.length - 1;
    } else {
      return;
    }

    e.preventDefault();
    const targetRound = allRounds[nextIndex];
    if (targetRound) {
      setActiveRoundNumber(targetRound.roundNumber);
      roundTabRefs.current[nextIndex]?.focus();
    }
  };

  return (
    <div className="space-y-8" role="region" aria-label="Tournament Bracket Progression">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_300px]">
        <div className="rounded-[28px] border border-border/80 bg-[radial-gradient(circle_at_top_left,_rgba(34,211,238,0.12),_transparent_28%),linear-gradient(135deg,_rgba(15,23,42,0.98),_rgba(30,41,59,0.96))] p-4 text-white shadow-[0_30px_80px_-45px_rgba(14,165,233,0.65)] sm:p-6">
          {/* Header & Controls */}
          <div className="mb-6 flex flex-wrap items-center justify-between gap-4">
            <div>
              <p className="text-xs uppercase tracking-[0.35em] text-cyan-200/70">
                Tournament Bracket
              </p>
              <h3 className="mt-1 text-2xl font-semibold">
                {processedBracketData.format === "double_elimination"
                  ? "Interactive Double Elimination Bracket"
                  : "Interactive Single Elimination Bracket"}
              </h3>
              <p className="mt-2 max-w-2xl text-sm text-slate-300">
                Accessible match progression with text labels, round navigation, and semantic list alternatives.
              </p>
            </div>

            {/* View Mode Switcher (#32) */}
            <div
              className="flex items-center rounded-xl border border-white/10 bg-slate-900/80 p-1"
              role="group"
              aria-label="Bracket view options"
            >
              <button
                type="button"
                onClick={() => setViewMode("tree")}
                className={cn(
                  "flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition-colors",
                  viewMode === "tree"
                    ? "bg-primary text-white shadow-sm"
                    : "text-slate-400 hover:text-white",
                )}
                aria-pressed={viewMode === "tree"}
                title="Interactive Visual Tree View"
              >
                <LayoutGrid className="h-3.5 w-3.5" aria-hidden="true" />
                <span>Tree</span>
              </button>
              <button
                type="button"
                onClick={() => setViewMode("rounds")}
                className={cn(
                  "flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition-colors",
                  viewMode === "rounds"
                    ? "bg-primary text-white shadow-sm"
                    : "text-slate-400 hover:text-white",
                )}
                aria-pressed={viewMode === "rounds"}
                title="Round-by-Round Bounded View"
              >
                <ListFilter className="h-3.5 w-3.5" aria-hidden="true" />
                <span>Rounds</span>
              </button>
              <button
                type="button"
                onClick={() => setViewMode("table")}
                className={cn(
                  "flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition-colors",
                  viewMode === "table"
                    ? "bg-primary text-white shadow-sm"
                    : "text-slate-400 hover:text-white",
                )}
                aria-pressed={viewMode === "table"}
                title="Semantic Accessible Table Alternative"
              >
                <TableIcon className="h-3.5 w-3.5" aria-hidden="true" />
                <span>Table</span>
              </button>
            </div>
          </div>

          {/* Accessible Legend with Text Labels (#32) */}
          <div className="mb-6 flex flex-wrap gap-2 text-xs text-slate-200" aria-label="Bracket status guide">
            <LegendPill icon={<Sparkles className="h-3.5 w-3.5" />} label="Your match" className="border-cyan-400/40 bg-cyan-400/10" />
            <LegendPill icon={<Activity className="h-3.5 w-3.5" />} label="In progress (Live)" className="border-emerald-400/40 bg-emerald-400/10" />
            <LegendPill icon={<CheckCircle2 className="h-3.5 w-3.5" />} label="Completed result" className="border-blue-400/40 bg-blue-400/10" />
            <LegendPill icon={<AlertTriangle className="h-3.5 w-3.5" />} label="Dispute pending" className="border-rose-400/40 bg-rose-400/10" />
            <LegendPill icon={<Clock3 className="h-3.5 w-3.5" />} label="Pending schedule" className="border-slate-500/40 bg-slate-500/10" />
            <LegendPill icon={<HelpCircle className="h-3.5 w-3.5" />} label="Bye (Auto advance)" className="border-amber-400/40 bg-amber-400/10" />
          </div>

          {/* Round Selector Bar (Keyboard Accessible Tablist) */}
          {allRounds.length > 0 && (
            <div className="mb-4">
              <div
                className="flex gap-2 overflow-x-auto pb-2 scrollbar-none"
                role="tablist"
                aria-label="Tournament rounds"
              >
                {allRounds.map((round, idx) => {
                  const isSelected = round.roundNumber === activeRoundNumber;
                  return (
                    <button
                      key={round.id}
                      ref={(el) => {
                        roundTabRefs.current[idx] = el;
                      }}
                      role="tab"
                      id={`round-tab-${round.roundNumber}`}
                      aria-selected={isSelected}
                      aria-controls={`round-panel-${round.roundNumber}`}
                      tabIndex={isSelected ? 0 : -1}
                      type="button"
                      onClick={() => setActiveRoundNumber(round.roundNumber)}
                      onKeyDown={(e) => handleRoundTabKeyDown(e, idx)}
                      className={cn(
                        "rounded-xl border px-4 py-2 text-xs font-semibold uppercase tracking-wider transition-all min-h-[38px] whitespace-nowrap",
                        isSelected
                          ? "border-cyan-400/80 bg-cyan-400/20 text-white shadow-sm ring-1 ring-cyan-400"
                          : "border-white/10 bg-slate-900/60 text-slate-400 hover:border-white/20 hover:text-white",
                      )}
                    >
                      {round.name || `Round ${round.roundNumber}`}
                      <span className="ml-1.5 text-[10px] text-slate-400">
                        ({round.matches.length})
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {/* ─────────────────────────────────────────────────────────────── */}
          {/* VIEW MODE 1: Semantic Accessible Table View (#32)              */}
          {/* ─────────────────────────────────────────────────────────────── */}
          {viewMode === "table" ? (
            <div className="overflow-x-auto rounded-2xl border border-white/10 bg-slate-950/60 p-4">
              <table
                className="w-full text-left text-sm text-slate-200"
                role="table"
                aria-label="Accessible Tournament Bracket Match Schedule and Results"
              >
                <caption className="sr-only">
                  List of all tournament matches, participants, scores, and status outcomes
                </caption>
                <thead className="border-b border-white/10 text-xs uppercase tracking-wider text-slate-400">
                  <tr>
                    <th scope="col" className="py-3 px-3">Round</th>
                    <th scope="col" className="py-3 px-3">Match</th>
                    <th scope="col" className="py-3 px-3">Player 1</th>
                    <th scope="col" className="py-3 px-3">Player 2</th>
                    <th scope="col" className="py-3 px-3">Status</th>
                    <th scope="col" className="py-3 px-3">Score / Result</th>
                    <th scope="col" className="py-3 px-3">Action</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-white/5">
                  {allRounds.flatMap((round) =>
                    round.matches.map((match) => {
                      const isBye = Boolean(match.player1 && !match.player2);
                      const isWinnerP1 = match.winnerId && match.player1?.id === match.winnerId;
                      const isWinnerP2 = match.winnerId && match.player2?.id === match.winnerId;
                      const statusText = getAccessibleMatchStatus(match, isBye);

                      return (
                        <tr
                          key={match.id}
                          className="hover:bg-white/5 transition-colors"
                          tabIndex={0}
                          aria-label={`Match ${match.id} in ${round.name}: ${match.player1?.username ?? "TBD"} versus ${match.player2?.username ?? (isBye ? "Bye" : "TBD")}. Status: ${statusText}`}
                        >
                          <td className="py-3 px-3 font-medium text-slate-300">
                            {round.name}
                          </td>
                          <td className="py-3 px-3 text-xs text-slate-400 font-mono">
                            #{match.id.slice(-6)}
                          </td>
                          <td className="py-3 px-3">
                            <span className={cn(isWinnerP1 && "font-semibold text-emerald-300")}>
                              {match.player1?.username ?? "Awaiting Result"}
                              {match.player1?.isCurrentUser && " (You)"}
                            </span>
                          </td>
                          <td className="py-3 px-3">
                            {isBye ? (
                              <span className="text-amber-300 font-medium">
                                [Bye - Advances automatically]
                              </span>
                            ) : (
                              <span className={cn(isWinnerP2 && "font-semibold text-emerald-300")}>
                                {match.player2?.username ?? "Awaiting Result"}
                                {match.player2?.isCurrentUser && " (You)"}
                              </span>
                            )}
                          </td>
                          <td className="py-3 px-3">
                            <MatchStatusBadge status={match.status} isBye={isBye} />
                          </td>
                          <td className="py-3 px-3 font-semibold">
                            {typeof match.scorePlayer1 === "number" && typeof match.scorePlayer2 === "number"
                              ? `${match.scorePlayer1} - ${match.scorePlayer2}`
                              : isBye
                              ? "Advancement"
                              : "Pending"}
                          </td>
                          <td className="py-3 px-3">
                            <button
                              type="button"
                              onClick={() => setSelectedMatch(match)}
                              className="rounded-lg bg-white/10 px-2.5 py-1 text-xs font-medium text-white hover:bg-white/20"
                              aria-label={`View full details for match ${match.id}`}
                            >
                              Details
                            </button>
                          </td>
                        </tr>
                      );
                    }),
                  )}
                </tbody>
              </table>
            </div>
          ) : viewMode === "rounds" || isLargeBracket ? (
            /* ───────────────────────────────────────────────────────────── */
            /* VIEW MODE 2: Bounded Round View (avoids unbounded DOM #32)   */
            /* ───────────────────────────────────────────────────────────── */
            <div
              id={`round-panel-${selectedRound?.roundNumber}`}
              role="tabpanel"
              aria-labelledby={`round-tab-${selectedRound?.roundNumber}`}
              className="space-y-4"
            >
              <div className="flex items-center justify-between border-b border-white/10 pb-3">
                <h4 className="text-sm font-semibold uppercase tracking-wider text-slate-200">
                  {selectedRound?.name}
                </h4>
                <span className="text-xs text-slate-400">
                  Showing {selectedRound?.matches.length ?? 0} matches
                </span>
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                {selectedRound?.matches.map((match) => (
                  <MatchCard
                    key={match.id}
                    match={match}
                    onSelectMatch={setSelectedMatch}
                    isHighlighted={highlightedMatchId === match.id}
                  />
                ))}
              </div>
            </div>
          ) : (
            /* ───────────────────────────────────────────────────────────── */
            /* VIEW MODE 3: Visual Interactive Tree View                    */
            /* ───────────────────────────────────────────────────────────── */
            <div className="overflow-x-auto rounded-2xl border border-white/10 bg-slate-950/40 p-4">
              <div
                className="flex gap-14 min-w-max pb-4"
                role="region"
                aria-label="Single elimination progression tree"
              >
                {allRounds.map((round) => (
                  <div key={round.id} className="w-[280px] flex-shrink-0 space-y-4">
                    <div className="border-b border-white/10 pb-2">
                      <p className="text-xs font-semibold uppercase tracking-wider text-slate-300">
                        {round.name}
                      </p>
                      <p className="text-[11px] text-slate-500">
                        {round.matches.length} {round.matches.length === 1 ? "match" : "matches"}
                      </p>
                    </div>
                    <div className="flex flex-col justify-around gap-6">
                      {round.matches.map((match) => (
                        <MatchCard
                          key={match.id}
                          match={match}
                          onSelectMatch={setSelectedMatch}
                          isHighlighted={highlightedMatchId === match.id}
                        />
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Sidebar Summary & Stats */}
        <div className="space-y-4">
          <div className="rounded-2xl border border-border bg-card p-5 text-card-foreground">
            <div className="flex items-center gap-3">
              <Trophy className="h-5 w-5 text-primary" aria-hidden="true" />
              <h4 className="text-base font-semibold">Tournament Overview</h4>
            </div>
            <div className="mt-4 grid grid-cols-2 gap-3 text-xs">
              <StatCard label="Total Rounds" value={String(allRounds.length)} />
              <StatCard label="Total Matches" value={String(totalMatches)} />
              <StatCard
                label="Completed"
                value={String(
                  allRounds
                    .flatMap((r) => r.matches)
                    .filter((m) => m.status === "completed").length,
                )}
              />
              <StatCard
                label="Disputes"
                value={String(
                  allRounds
                    .flatMap((r) => r.matches)
                    .filter((m) => m.status === "disputed").length,
                )}
              />
            </div>
          </div>
        </div>
      </div>

      {/* Match Details Modal */}
      {selectedMatch && (
        <BracketMatchModal
          match={selectedMatch}
          onClose={() => setSelectedMatch(null)}
        />
      )}
    </div>
  );
}

// ─── Match Card Component (#32) ───────────────────────────────────────────────

function MatchCard({
  match,
  onSelectMatch,
  isHighlighted = false,
}: {
  match: BracketMatch;
  onSelectMatch: (match: BracketMatch) => void;
  isHighlighted?: boolean;
}) {
  const isBye = Boolean(match.player1 && !match.player2);
  const statusLabel = getAccessibleMatchStatus(match, isBye);

  const accessibleCardLabel = `Match #${match.id.slice(-6)}: ${match.player1?.username ?? "TBD"} versus ${
    match.player2?.username ?? (isBye ? "Bye" : "TBD")
  }. Status: ${statusLabel}. Score: ${
    match.scorePlayer1 ?? 0
  } to ${match.scorePlayer2 ?? 0}. Click or press enter for full details.`;

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      onSelectMatch(match);
    }
  };

  return (
    <div
      id={bracketMatchDomId(match.id)}
      role="button"
      tabIndex={0}
      aria-label={accessibleCardLabel}
      onClick={() => onSelectMatch(match)}
      onKeyDown={handleKeyDown}
      className={cn(
        "group relative flex flex-col justify-between rounded-2xl border p-3.5 transition-all cursor-pointer focus:outline-none focus:ring-2 focus:ring-cyan-400",
        isHighlighted
          ? "border-cyan-400 bg-cyan-950/40 shadow-lg shadow-cyan-500/20 ring-1 ring-cyan-400"
          : "border-white/10 bg-slate-900/80 hover:border-white/25 hover:bg-slate-900",
      )}
    >
      <div className="flex items-center justify-between gap-2 border-b border-white/5 pb-2">
        <span className="font-mono text-[11px] text-slate-400">
          #{match.id.slice(-6)}
        </span>
        <MatchStatusBadge status={match.status} isBye={isBye} />
      </div>

      <div className="mt-2 space-y-1.5">
        <PlayerRow
          player={match.player1}
          score={match.scorePlayer1}
          isWinner={Boolean(match.winnerId && match.player1?.id === match.winnerId)}
        />
        <PlayerRow
          player={match.player2}
          score={match.scorePlayer2}
          isWinner={Boolean(match.winnerId && match.player2?.id === match.winnerId)}
          isBye={isBye}
        />
      </div>

      {match.conflictReason && (
        <div className="mt-2 rounded-lg bg-rose-500/10 px-2 py-1 text-[11px] text-rose-300">
          Dispute: {match.conflictReason}
        </div>
      )}
    </div>
  );
}

// ─── Player Row Component ─────────────────────────────────────────────────────

function PlayerRow({
  player,
  score,
  isWinner,
  isBye = false,
}: {
  player: BracketMatch["player1"];
  score?: number;
  isWinner: boolean;
  isBye?: boolean;
}) {
  if (isBye) {
    return (
      <div className="flex items-center justify-between rounded-xl bg-amber-500/10 px-2.5 py-1.5 text-amber-200">
        <span className="text-xs font-semibold">[Bye - Advances automatically]</span>
        <span className="text-xs uppercase tracking-wider text-amber-400">BYE</span>
      </div>
    );
  }

  return (
    <div
      className={cn(
        "flex items-center justify-between rounded-xl px-2.5 py-1.5 transition-colors",
        isWinner ? "bg-emerald-500/20 text-emerald-200" : "bg-white/5 text-slate-200",
      )}
    >
      <div className="flex min-w-0 items-center gap-2">
        <div className="flex h-6 w-6 items-center justify-center rounded-lg bg-white/10 text-slate-400">
          <User className="h-3.5 w-3.5" aria-hidden="true" />
        </div>
        <p className="truncate text-xs font-medium">
          {player?.username ?? "Awaiting Result"}
          {player?.isCurrentUser && (
            <span className="ml-1 text-[10px] text-cyan-300 uppercase tracking-wider font-semibold">
              (You)
            </span>
          )}
        </p>
      </div>
      <div className="ml-2 font-mono text-xs font-semibold">
        {typeof score === "number" ? score : "-"}
      </div>
    </div>
  );
}

// ─── Match Status Badge (Distinct Text Labels #32) ────────────────────────────

function MatchStatusBadge({
  status,
  isBye = false,
}: {
  status: BracketMatch["status"];
  isBye?: boolean;
}) {
  if (isBye) {
    return (
      <span className="rounded-full bg-amber-500/20 border border-amber-400/40 px-2 py-0.5 text-[10px] font-semibold text-amber-200 uppercase tracking-wider">
        Bye
      </span>
    );
  }

  const badgeConfig = {
    pending: {
      label: "Pending",
      className: "bg-slate-500/20 border border-slate-400/40 text-slate-300",
    },
    ready: {
      label: "Ready",
      className: "bg-cyan-500/20 border border-cyan-400/40 text-cyan-200",
    },
    in_progress: {
      label: "Live Match",
      className: "bg-emerald-500/20 border border-emerald-400/40 text-emerald-200 animate-pulse",
    },
    completed: {
      label: "Completed",
      className: "bg-blue-500/20 border border-blue-400/40 text-blue-200",
    },
    disputed: {
      label: "Disputed",
      className: "bg-rose-500/20 border border-rose-400/40 text-rose-200 font-bold",
    },
  } as const;

  const conf = badgeConfig[status] ?? badgeConfig.pending;

  return (
    <span
      className={cn(
        "rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider",
        conf.className,
      )}
    >
      {conf.label}
    </span>
  );
}

function getAccessibleMatchStatus(match: BracketMatch, isBye: boolean): string {
  if (isBye) return "Bye - player automatically advances to the next round";
  if (match.status === "disputed") {
    return `Disputed: ${match.conflictReason ?? "Score dispute under investigation"}`;
  }
  if (match.status === "completed") {
    return `Completed: Match concluded with final score ${match.scorePlayer1 ?? 0} to ${match.scorePlayer2 ?? 0}`;
  }
  if (match.status === "in_progress") return "In Progress - Live game ongoing";
  if (match.status === "ready") return "Ready to start";
  return "Pending - Waiting for previous match results";
}

function LegendPill({
  icon,
  label,
  className,
}: {
  icon: ReactNode;
  label: string;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 font-medium",
        className,
      )}
    >
      {icon}
      {label}
    </span>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-border bg-slate-50 dark:bg-slate-900 px-3 py-2">
      <p className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</p>
      <p className="mt-1 text-base font-semibold text-foreground">{value}</p>
    </div>
  );
}
