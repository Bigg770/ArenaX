/**
 * Accessible Tournament Bracket Tests — Issue #32.
 *
 * Verifies that:
 * 1. Byes, pending matches, disputes, and completed results have distinct text labels, not color alone.
 * 2. Focus order and keyboard navigation remain usable across rounds.
 * 3. Large brackets avoid unbounded DOM/render cost through bounded views.
 * 4. A semantic list/table alternative is provided and fully accessible.
 * 5. Handles small, large, and incomplete brackets gracefully.
 */

import React from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import "@testing-library/jest-dom";
import { SingleEliminationBracket } from "@/components/bracket/SingleEliminationBracket";
import { BracketData } from "@/types/bracket";

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const mockSmallBracket: BracketData = {
  id: "bracket-small",
  tournamentId: "t-1",
  format: "single_elimination",
  sections: [
    {
      id: "sec-1",
      name: "Main Bracket",
      rounds: [
        {
          id: "r-1",
          roundNumber: 1,
          name: "Semifinals",
          matches: [
            {
              id: "m-1",
              round: 1,
              position: 0,
              status: "completed",
              player1: { id: "p1", username: "Alice", seed: 1 },
              player2: { id: "p2", username: "Bob", seed: 4 },
              scorePlayer1: 2,
              scorePlayer2: 1,
              winnerId: "p1",
            },
            {
              id: "m-2",
              round: 1,
              position: 1,
              status: "disputed",
              conflictReason: "Conflicting score reports submitted",
              player1: { id: "p3", username: "Charlie", seed: 2 },
              player2: { id: "p4", username: "Dave", seed: 3 },
              scorePlayer1: 2,
              scorePlayer2: 2,
            },
          ],
        },
        {
          id: "r-2",
          roundNumber: 2,
          name: "Finals",
          matches: [
            {
              id: "m-3",
              round: 2,
              position: 0,
              status: "pending",
              player1: { id: "p1", username: "Alice", seed: 1 },
              player2: null,
            },
          ],
        },
      ],
    },
  ],
};

const mockIncompleteBracketWithByes: BracketData = {
  id: "bracket-byes",
  tournamentId: "t-byes",
  format: "single_elimination",
  sections: [
    {
      id: "sec-1",
      name: "Main Bracket",
      rounds: [
        {
          id: "r-1",
          roundNumber: 1,
          name: "Round 1",
          matches: [
            {
              id: "m-bye",
              round: 1,
              position: 0,
              status: "completed",
              player1: { id: "p1", username: "SoloPlayer", seed: 1 },
              player2: null, // Bye!
              winnerId: "p1",
            },
            {
              id: "m-live",
              round: 1,
              position: 1,
              status: "in_progress",
              player1: { id: "p2", username: "PlayerTwo" },
              player2: { id: "p3", username: "PlayerThree" },
              scorePlayer1: 1,
              scorePlayer2: 0,
            },
          ],
        },
      ],
    },
  ],
};

function generateLargeBracket(matchCount: number): BracketData {
  const matches = Array.from({ length: matchCount }, (_, i) => ({
    id: `m-large-${i}`,
    round: 1,
    position: i,
    status: (i % 2 === 0 ? "completed" : "pending") as BracketData["sections"][0]["rounds"][0]["matches"][0]["status"],
    player1: { id: `p-${i * 2}`, username: `Player${i * 2}` },
    player2: { id: `p-${i * 2 + 1}`, username: `Player${i * 2 + 1}` },
  }));

  return {
    id: "bracket-large",
    tournamentId: "t-large",
    format: "single_elimination",
    sections: [
      {
        id: "sec-1",
        name: "Grand Championship",
        rounds: [
          {
            id: "r-large-1",
            roundNumber: 1,
            name: "Round of 64",
            matches,
          },
        ],
      },
    ],
  };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("Issue #32: Accessible Tournament Brackets", () => {
  describe("Text Labels for Match Outcomes (not color alone)", () => {
    it("renders distinct text label for completed matches and winners", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      expect(screen.getAllByText(/Completed/i).length).toBeGreaterThan(0);
      expect(screen.getByText("Alice")).toBeInTheDocument();
      expect(screen.getByText("Bob")).toBeInTheDocument();
    });

    it("renders distinct text label for disputed matches with reason", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      expect(screen.getAllByText(/Disputed/i).length).toBeGreaterThan(0);
      expect(
        screen.getByText(/Conflicting score reports submitted/i),
      ).toBeInTheDocument();
    });

    it("renders distinct text label for pending matches", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      expect(screen.getAllByText(/Pending/i).length).toBeGreaterThan(0);
    });

    it("renders explicit text label for byes", () => {
      render(<SingleEliminationBracket bracketData={mockIncompleteBracketWithByes} />);

      expect(screen.getAllByText(/Bye/i).length).toBeGreaterThan(0);
      expect(
        screen.getByText(/Bye - Advances automatically/i),
      ).toBeInTheDocument();
    });
  });

  describe("Keyboard Navigation & Focus Order", () => {
    it("provides accessible round tablist and changes rounds via arrow keys", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      const tablist = screen.getByRole("tablist", { name: /Tournament rounds/i });
      expect(tablist).toBeInTheDocument();

      const tabs = screen.getAllByRole("tab");
      expect(tabs.length).toBe(2);

      // Semifinals is active initially
      expect(tabs[0]).toHaveAttribute("aria-selected", "true");

      // Press ArrowRight to move to Finals
      fireEvent.keyDown(tabs[0], { key: "ArrowRight" });
      expect(tabs[1]).toHaveAttribute("aria-selected", "true");

      // Press ArrowLeft to return to Semifinals
      fireEvent.keyDown(tabs[1], { key: "ArrowLeft" });
      expect(tabs[0]).toHaveAttribute("aria-selected", "true");
    });

    it("ensures match cards are keyboard focusable with descriptive aria-label", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      const matchButtons = screen.getAllByRole("button", {
        name: /versus/i,
      });

      expect(matchButtons.length).toBeGreaterThan(0);
      expect(matchButtons[0]).toHaveAttribute("tabindex", "0");
      expect(matchButtons[0].getAttribute("aria-label")).toMatch(/Alice.*versus.*Bob/i);
    });
  });

  describe("Semantic List/Table Alternative", () => {
    it("toggles to accessible table view with full semantic table headers and rows", () => {
      render(<SingleEliminationBracket bracketData={mockSmallBracket} />);

      const tableButton = screen.getByRole("button", { name: /Table/i });
      fireEvent.click(tableButton);

      const table = screen.getByRole("table", {
        name: /Accessible Tournament Bracket Match Schedule/i,
      });
      expect(table).toBeInTheDocument();

      expect(screen.getByRole("columnheader", { name: /Round/i })).toBeInTheDocument();
      expect(screen.getByRole("columnheader", { name: /Player 1/i })).toBeInTheDocument();
      expect(screen.getByRole("columnheader", { name: /Player 2/i })).toBeInTheDocument();
      expect(screen.getByRole("columnheader", { name: /Status/i })).toBeInTheDocument();
    });
  });

  describe("Large Brackets Performance / Bounded Cost", () => {
    it("renders large brackets in bounded round view to prevent unbounded DOM costs", () => {
      const largeBracket = generateLargeBracket(40);
      render(<SingleEliminationBracket bracketData={largeBracket} />);

      // Should automatically render in bounded round view
      expect(screen.getByRole("tabpanel")).toBeInTheDocument();
      expect(screen.getByText(/Showing 40 matches/i)).toBeInTheDocument();
    });
  });
});
