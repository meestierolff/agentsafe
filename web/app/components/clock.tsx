"use client";

import { useEffect, useState } from "react";

/** "Fri 11:06 PM" in the visitor's own time zone. Filled in after load, so the server and browser agree. */
export function Clock() {
  const [text, setText] = useState("");
  useEffect(() => {
    const tick = () => {
      const now = new Date();
      setText(`${now.toLocaleDateString("en-US", { weekday: "short" })} ${now.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}`);
    };
    tick();
    const timer = setInterval(tick, 15_000);
    return () => clearInterval(timer);
  }, []);
  return <span suppressHydrationWarning>{text}</span>;
}

/** The dock calendar: today's month and day, in the visitor's time zone. */
export function CalendarDate({ month, day }: { month: string; day: number }) {
  const [value, setValue] = useState({ month, day });
  useEffect(() => {
    const now = new Date();
    setValue({ month: now.toLocaleDateString("en-US", { month: "short" }).toUpperCase(), day: now.getDate() });
  }, []);
  return (
    <>
      <div className="month"><span>{value.month}</span></div>
      <div className="day">{value.day}</div>
    </>
  );
}
