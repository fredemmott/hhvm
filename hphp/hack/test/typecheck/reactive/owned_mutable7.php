<?hh

function f(): void {
  // ERROR
  $z = function(<<__OwnedMutable>> A $c): void {
  };
}
