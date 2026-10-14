export function PageHeader({
  title,
  description,
}: {
  title: string
  description?: string
}) {
  return (
    <header className="mb-6">
      <h1 className="text-2xl font-semibold tracking-tight text-foreground md:text-[1.75rem]">
        {title}
      </h1>
      {description ? (
        <p className="mt-1.5 max-w-2xl text-sm leading-6 text-muted-foreground">
          {description}
        </p>
      ) : null}
    </header>
  )
}
