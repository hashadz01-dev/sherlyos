import { Bell, Menu } from "lucide-react"
import { useNavigate } from "react-router"
import { findNavigationItem } from "@/app/navigation"
import { BrandMark } from "@/components/layout/BrandMark"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverHeader,
  PopoverTitle,
  PopoverTrigger,
} from "@/components/ui/popover"
import { useAuth } from "@/hooks/use-auth"
import { emailInitial } from "@/lib/utilities/email-initial"
import { useUiStore } from "@/stores/ui-store"

export function TopBar({ pathname }: { pathname: string }) {
  const navigate = useNavigate()
  const { session, signOut } = useAuth()
  const setMobileNavOpen = useUiStore((state) => state.setMobileNavOpen)
  const current = findNavigationItem(pathname)
  const email = session?.user.email

  async function handleSignOut() {
    await signOut()
    await navigate("/login")
  }

  return (
    <header className="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-slate-200/80 bg-white/95 px-4 backdrop-blur md:px-6">
      <Button
        type="button"
        variant="outline"
        size="icon"
        className="md:hidden"
        aria-label="Open navigation"
        onClick={() => setMobileNavOpen(true)}
      >
        <Menu />
      </Button>
      <div className="min-w-0 md:hidden">
        <BrandMark compact tone="dark" />
      </div>
      <div className="hidden min-w-0 md:block">
        <p className="truncate text-sm font-medium text-foreground">
          {current?.title ?? "SherlysOS"}
        </p>
      </div>
      <div className="ml-auto flex items-center gap-2">
        <Popover>
          <PopoverTrigger asChild>
            <Button
              type="button"
              variant="outline"
              size="icon"
              aria-label="Notifications"
            >
              <Bell />
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-80">
            <PopoverHeader>
              <PopoverTitle>Notifications</PopoverTitle>
              <PopoverDescription>
                No notifications. Workflow alerts will appear here after the
                modules are connected.
              </PopoverDescription>
            </PopoverHeader>
          </PopoverContent>
        </Popover>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              type="button"
              variant="outline"
              className="h-8 gap-2 px-1.5"
              aria-label="Account menu"
            >
              <Avatar size="sm">
                <AvatarFallback className="bg-brand/10 text-xs font-semibold text-brand">
                  {emailInitial(email)}
                </AvatarFallback>
              </Avatar>
              <span className="hidden max-w-40 truncate text-sm font-medium sm:inline">
                {email ?? "Signed in"}
              </span>
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-64">
            <DropdownMenuLabel className="font-normal">
              <span className="block text-xs text-muted-foreground">
                Signed in as
              </span>
              <span className="mt-1 block truncate text-sm font-medium">
                {email ?? "Signed in"}
              </span>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem onSelect={() => void handleSignOut()}>
              Sign out
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </header>
  )
}
